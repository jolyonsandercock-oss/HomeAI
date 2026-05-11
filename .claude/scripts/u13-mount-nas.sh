#!/bin/bash
# /home_ai/.claude/scripts/u13-mount-nas.sh
#
# U13 Stage C — interactive NAS mount + Restic repoint.
#
# What this does (idempotent — safe to re-run):
#   1. Prompts for NAS protocol (SMB/CIFS or NFS) + host + share + creds
#   2. Stores SMB credentials in /root/.homeai-nas-creds (mode 600)
#   3. Adds an fstab entry for /mnt/mycloud (idempotent)
#   4. Tests the mount; bails on failure
#   5. Initialises a fresh Restic repo on the NAS at /mnt/mycloud/restic
#   6. `restic copy` from local repo to NAS — preserves snapshot IDs + dedupe
#   7. Writes /home_ai/backups/.restic-repo with NAS path so backup scripts pick it up
#   8. Installs the weekly DR cron line (if not already present)
#
# What this does NOT do:
#   - Delete the local repo (kept as warm spare for ~30 days; manual cleanup later)
#   - Change Vault, n8n, or any service config — backups only
#   - Schedule offsite/cloud copy (phase 2.5 — separate decision)
#
# Run as root (the fstab + creds writes need it):
#   sudo bash /home_ai/.claude/scripts/u13-mount-nas.sh
#
# Recovery: if any step fails, the script aborts and prints what it tried.
# Re-running picks up where it stopped.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "✗ this script needs root for fstab + cred file writes"
  echo "  re-run as: sudo bash $0"
  exit 1
fi

MOUNT_POINT="/mnt/mycloud"
CREDS_FILE="/root/.homeai-nas-creds"
RESTIC_REPO_FILE="/home_ai/backups/.restic-repo"
LOCAL_REPO="/home_ai/backups/restic-local"
PW_FILE="/home_ai/backups/.restic-pw"

echo "── U13 Stage C: NAS mount + Restic repoint ──"
echo

# ── 1. Pick a protocol ────────────────────────────────────────────
echo "Pick a protocol:"
echo "  [1] SMB / CIFS  (Western Digital MyCloud, Synology default share)"
echo "  [2] NFS         (Synology, TrueNAS, QNAP)"
read -rp "Choice [1/2]: " PROTO_CHOICE
case "$PROTO_CHOICE" in
  1) PROTO=cifs ;;
  2) PROTO=nfs  ;;
  *) echo "✗ invalid choice"; exit 1 ;;
esac

# ── 2. Gather connection details ──────────────────────────────────
read -rp "NAS hostname or IP: " NAS_HOST
[[ -z "$NAS_HOST" ]] && { echo "✗ host cannot be empty"; exit 1; }

if [[ "$PROTO" == "cifs" ]]; then
  read -rp "SMB share name (e.g. 'TimeMachineBackup'): " NAS_SHARE
  read -rp "SMB username: " NAS_USER
  read -rsp "SMB password (silent): " NAS_PASS; echo
  REMOTE="//${NAS_HOST}/${NAS_SHARE}"
  FSTAB_OPTS="credentials=${CREDS_FILE},uid=$(id -u joly),gid=$(id -g joly),iocharset=utf8,vers=3.0,nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=60"
else
  read -rp "NFS export path (e.g. '/volume1/homeai-backups'): " NFS_PATH
  REMOTE="${NAS_HOST}:${NFS_PATH}"
  FSTAB_OPTS="rw,nofail,_netdev,soft,timeo=30,x-systemd.automount,x-systemd.idle-timeout=60"
fi

# ── 3. Install required packages ──────────────────────────────────
echo "→ ensuring mount tooling"
case "$PROTO" in
  cifs) dpkg -s cifs-utils >/dev/null 2>&1 || apt-get install -y --no-install-recommends cifs-utils ;;
  nfs)  dpkg -s nfs-common >/dev/null 2>&1 || apt-get install -y --no-install-recommends nfs-common ;;
esac

# ── 4. Mount point ────────────────────────────────────────────────
mkdir -p "$MOUNT_POINT"

# ── 5. Credentials file (SMB only) ────────────────────────────────
if [[ "$PROTO" == "cifs" ]]; then
  echo "→ writing $CREDS_FILE (mode 600)"
  umask 077
  cat > "$CREDS_FILE" <<EOF
username=$NAS_USER
password=$NAS_PASS
EOF
  unset NAS_PASS
  chmod 600 "$CREDS_FILE"
fi

# ── 6. fstab (idempotent — replace any existing line for this mountpoint) ──
echo "→ updating /etc/fstab"
cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
sed -i "\|[[:space:]]${MOUNT_POINT}[[:space:]]|d" /etc/fstab
echo "${REMOTE} ${MOUNT_POINT} ${PROTO} ${FSTAB_OPTS} 0 0" >> /etc/fstab

# ── 7. Mount + smoke test ─────────────────────────────────────────
echo "→ mounting"
if mountpoint -q "$MOUNT_POINT"; then
  umount "$MOUNT_POINT" || { echo "✗ stale mount, please reboot and re-run"; exit 1; }
fi
mount "$MOUNT_POINT" || { echo "✗ mount failed — check fstab line + creds"; exit 1; }
mountpoint -q "$MOUNT_POINT" || { echo "✗ mount didn't take"; exit 1; }

# Sanity: can we write?
TEST_FILE="$MOUNT_POINT/.homeai-mount-test"
if ! touch "$TEST_FILE" 2>/dev/null; then
  echo "✗ NAS is mounted read-only or the share isn't writable. Aborting."
  umount "$MOUNT_POINT" || true
  exit 1
fi
rm -f "$TEST_FILE"
echo "  ✓ mounted + writable"

# ── 8. Restic repo on NAS ─────────────────────────────────────────
NAS_RESTIC_REPO="$MOUNT_POINT/restic-homeai"
mkdir -p "$NAS_RESTIC_REPO"

echo "→ ensuring NAS restic repo exists"
if RESTIC_REPOSITORY="$NAS_RESTIC_REPO" RESTIC_PASSWORD_FILE="$PW_FILE" restic snapshots >/dev/null 2>&1; then
  echo "  ✓ NAS repo already initialised"
else
  echo "  initialising NAS repo at $NAS_RESTIC_REPO"
  RESTIC_REPOSITORY="$NAS_RESTIC_REPO" RESTIC_PASSWORD_FILE="$PW_FILE" restic init
fi

# ── 9. Copy local snapshots to NAS (preserves IDs, dedupes) ───────
if [[ -d "$LOCAL_REPO/snapshots" ]] && [[ -n "$(find "$LOCAL_REPO/snapshots" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "→ copying local restic snapshots to NAS (one-time sync)"
  RESTIC_REPOSITORY="$NAS_RESTIC_REPO" RESTIC_PASSWORD_FILE="$PW_FILE" \
    restic copy --from-repo "$LOCAL_REPO" --from-password-file "$PW_FILE" || {
      echo "  ⚠ copy hit a snag — review output above. NAS repo still usable for fresh snapshots."
    }
else
  echo "  (no local snapshots to copy)"
fi

# ── 10. Repoint backup scripts via env file ───────────────────────
echo "→ writing $RESTIC_REPO_FILE so nightly+weekly scripts use NAS"
echo "RESTIC_REPO=$NAS_RESTIC_REPO" > "$RESTIC_REPO_FILE"
chmod 644 "$RESTIC_REPO_FILE"

# ── 11. Weekly DR cron (idempotent) ───────────────────────────────
WEEKLY_LINE="0 4 * * 0 RESTIC_REPO=$NAS_RESTIC_REPO /home_ai/scripts/backup-all.sh >> /home_ai/backups/backup-all.log 2>&1"
USER_CRONTAB=$(crontab -u joly -l 2>/dev/null || true)
if echo "$USER_CRONTAB" | grep -qF '/home_ai/scripts/backup-all.sh'; then
  echo "  ✓ weekly DR cron already installed"
else
  (echo "$USER_CRONTAB"; echo "$WEEKLY_LINE") | grep -v '^$' | crontab -u joly -
  echo "  ✓ installed weekly DR cron line for user 'joly'"
fi

# ── 12. Tell nightly to read the env file ─────────────────────────
# backup-nightly.sh already honours RESTIC_REPO env. We rely on the cron line
# to set it, so update the existing nightly cron line to source the env file.
NIGHTLY_LINE="0 3 * * * source /home_ai/backups/.restic-repo && /home_ai/scripts/backup-nightly.sh >> /home_ai/backups/cron.log 2>&1"
USER_CRONTAB=$(crontab -u joly -l 2>/dev/null || true)
if echo "$USER_CRONTAB" | grep -qF 'source /home_ai/backups/.restic-repo'; then
  echo "  ✓ nightly cron already sources NAS env"
else
  echo "  updating nightly cron to source NAS env file"
  echo "$USER_CRONTAB" | grep -v 'backup-nightly.sh' | { cat; echo "$NIGHTLY_LINE"; } | grep -v '^$' | crontab -u joly -
fi

echo
echo "── DONE ──"
echo
echo "Mount   : $REMOTE → $MOUNT_POINT ($PROTO)"
echo "Restic  : $NAS_RESTIC_REPO"
echo "Crons   : daily 03:00 + weekly 04:00 Sun (user 'joly')"
echo
echo "Verify in 24 hours:"
echo "  tail -30 /home_ai/backups/cron.log"
echo "  RESTIC_REPOSITORY=$NAS_RESTIC_REPO RESTIC_PASSWORD_FILE=$PW_FILE restic snapshots --compact"
echo
echo "Local repo at $LOCAL_REPO is kept as a warm spare. Delete in ~30 days"
echo "after verifying NAS snapshots have been retained correctly:"
echo "  rm -rf $LOCAL_REPO"
