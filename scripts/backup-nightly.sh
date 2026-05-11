#!/bin/bash
# /home_ai/scripts/backup-nightly.sh
# Nightly backup — runs from cron at 03:00 (see install-cron.sh).
#
# Snapshots:
#   1. PostgreSQL `homeai` DB dump (pg_dump --format=custom)
#   2. n8n_data Docker volume (tar)
#   3. vault_data Docker volume (tar; encrypted blob — useless without unseal keys)
#   4. /home_ai/postgres + /home_ai/monitoring + /home_ai/.claude (config files)
#
# Restic destination: /home_ai/backups/restic-local. When the NAS is mounted
# (e.g. /mnt/mycloud), update REPO_PATH and re-init the repo there with
# `restic init -p /home_ai/backups/.restic-pw -r /mnt/mycloud/restic`.
#
# Per SPEC: restic password is NOT stored in Vault — Vault might be sealed
# during a recovery scenario, so the password lives in a chmod 600 file on
# the host (back this file up offline, e.g. write the contents on paper).

set -euo pipefail

REPO_PATH="${RESTIC_REPO:-/home_ai/backups/restic-local}"
PW_FILE="/home_ai/backups/.restic-pw"
STAGING="/home_ai/backups/staging"
LOG_FILE="/home_ai/backups/last-backup.log"

export RESTIC_REPOSITORY="$REPO_PATH"
export RESTIC_PASSWORD_FILE="$PW_FILE"

started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
exec > >(tee -a "$LOG_FILE") 2>&1
echo "── Home AI backup started $started ──"

# Initialise repo on first run
if ! restic snapshots >/dev/null 2>&1; then
  echo "→ initialising restic repo at $REPO_PATH"
  restic init
fi

# Clean staging
rm -rf "$STAGING" && mkdir -p "$STAGING"

# 1. Postgres dump (homeai DB only — metabase_app is recreated on demand)
echo "→ dumping homeai database"
docker exec homeai-postgres pg_dump -U postgres -d homeai --format=custom \
  > "$STAGING/homeai.pgdump"

# 2. n8n_data volume (workflow definitions, encrypted credentials, executions DB)
echo "→ archiving n8n_data volume"
docker run --rm -v home_ai_n8n_data:/src:ro \
  -v "$STAGING":/dst alpine \
  tar czf /dst/n8n_data.tar.gz -C /src .

# 3. vault_data volume (sealed — recovery requires offline unseal keys)
echo "→ archiving vault_data volume"
docker run --rm -v home_ai_vault_data:/src:ro \
  -v "$STAGING":/dst alpine \
  tar czf /dst/vault_data.tar.gz -C /src .

# 4. Config tree (idempotent — restic dedupes unchanged blobs)
echo "→ snapshotting config tree + staged blobs"
restic backup \
  --tag homeai-nightly \
  --tag "phase=1" \
  --exclude '/home_ai/backups' \
  --exclude '/home_ai/.git' \
  --exclude 'node_modules' \
  --exclude '*.pyc' \
  --exclude '__pycache__' \
  /home_ai/postgres \
  /home_ai/monitoring \
  /home_ai/.claude \
  /home_ai/scripts \
  /home_ai/docker-compose.yml \
  /home_ai/AGENTS.md \
  /home_ai/SPEC.md \
  /home_ai/HOME-AI-STRETCH.md \
  /home_ai/start.sh \
  "$STAGING"

# Retention: 7 daily, 4 weekly, 6 monthly. Forget + prune in one pass.
echo "→ enforcing retention (7d 4w 6m)"
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# Cleanup staging
rm -rf "$STAGING"

# Final summary
echo "→ snapshot count:"
restic snapshots --compact | tail -5

echo "── backup complete $(date -u '+%Y-%m-%dT%H:%M:%SZ') ──"
