#!/usr/bin/env bash
# box-hardening-root.sh — one-shot Ubuntu box hygiene (2026-06-11).
# Run as:  sudo bash /home_ai/scripts/box-hardening-root.sh
# Re-runnable: every step is idempotent.
#
# Docker log rotation needs a docker daemon restart (bounces every container),
# so it is NOT done by default. Run with --with-docker-restart to include it
# (good moment: 48GB GPU install downtime).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

echo "== 1. vm.swappiness=10 (107GB RAM box; was 60) =="
cat > /etc/sysctl.d/99-homeai.conf <<'EOF'
vm.swappiness = 10
EOF
sysctl -p /etc/sysctl.d/99-homeai.conf

echo "== 2. journald cap 1G (was 3.3G on disk) =="
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-homeai.conf <<'EOF'
[Journal]
SystemMaxUse=1G
EOF
systemctl restart systemd-journald
journalctl --vacuum-size=1G

echo "== 3. smartmontools + nvme-cli =="
DEBIAN_FRONTEND=noninteractive apt-get install -y -q smartmontools nvme-cli >/dev/null
cat > /usr/local/bin/disk-health-check.sh <<'EOF'
#!/usr/bin/env bash
# Weekly disk health: SMART on the HDD, health log on the NVMe.
# On any failure, writes /home_ai/logs/DISK_FAILURE.flag (picked up manually /
# by future heartbeat wiring) and logs detail.
LOG=/home_ai/logs/disk-health.log
FAIL=0
{
  echo "=== $(date -Is) ==="
  for d in /dev/sd?; do
    [ -b "$d" ] || continue
    out=$(smartctl -H "$d" 2>&1)
    echo "$d: $(echo "$out" | grep -E 'overall-health|SMART Health' || echo 'no verdict')"
    echo "$out" | grep -qiE 'PASSED|OK' || FAIL=1
  done
  for n in /dev/nvme?; do
    [ -c "$n" ] || continue
    out=$(nvme smart-log "$n" 2>&1)
    cw=$(echo "$out" | awk -F: '/critical_warning/{gsub(/ /,"",$2); print $2}')
    pu=$(echo "$out" | awk -F: '/percentage_used/{gsub(/[ %]/,"",$2); print $2}')
    echo "$n: critical_warning=$cw percentage_used=${pu}%"
    [ "${cw:-0}" = "0" ] || FAIL=1
  done
} >> "$LOG" 2>&1
if [ "$FAIL" = 1 ]; then touch /home_ai/logs/DISK_FAILURE.flag; else rm -f /home_ai/logs/DISK_FAILURE.flag; fi
EOF
chmod 755 /usr/local/bin/disk-health-check.sh
cat > /etc/cron.d/homeai-disk-health <<'EOF'
15 6 * * 1 root /usr/local/bin/disk-health-check.sh
EOF
/usr/local/bin/disk-health-check.sh
tail -5 /home_ai/logs/disk-health.log

echo "== 4. Backup mirror dir on the 5.5TB HDD =="
mkdir -p /mnt/shared_storage/backups
chown joly:joly /mnt/shared_storage/backups
# joly-side mirror cron (04:30, after the 03:00 backup):
MIRROR='30 4 * * * rsync -a --delete /home_ai/backups/restic-local/ /mnt/shared_storage/backups/restic-local/ >> /home_ai/backups/mirror.log 2>&1'
crontab -u joly -l 2>/dev/null | grep -qF 'shared_storage/backups/restic-local' || \
  ( crontab -u joly -l 2>/dev/null; echo "$MIRROR" ) | crontab -u joly -

echo "== 5. Root-owned files into backup reach =="
# The 03:00 backup runs as joly and cannot read root-owned 0700 ops files
# (missed vault-watchdog.sh etc on 2026-05-30). Stage copies it CAN read.
cat > /etc/cron.d/homeai-rootfiles-stage <<'EOF'
50 2 * * * root mkdir -p /home_ai/backups/root-files && for f in /usr/local/bin/*.sh /etc/systemd/system/vault-watchdog.* /etc/cron.d/homeai-*; do [ -e "$f" ] && install -m 640 -o root -g joly "$f" /home_ai/backups/root-files/; done
EOF
# run the same staging once now
mkdir -p /home_ai/backups/root-files
for f in /usr/local/bin/*.sh /etc/systemd/system/vault-watchdog.* /etc/cron.d/homeai-*; do
  [ -e "$f" ] && install -m 640 -o root -g joly "$f" /home_ai/backups/root-files/
done
ls -la /home_ai/backups/root-files/ | head -10

if [[ "${1:-}" == "--with-docker-restart" ]]; then
  echo "== 6. Docker json-file log rotation (RESTARTS ALL CONTAINERS) =="
  python3 - <<'EOF'
import json
p = '/etc/docker/daemon.json'
cfg = json.load(open(p))
cfg['log-driver'] = 'json-file'
cfg['log-opts'] = {'max-size': '20m', 'max-file': '3'}
json.dump(cfg, open(p, 'w'), indent=4)
EOF
  systemctl restart docker
  echo "Docker restarted — verify the stack: bash /home_ai/scripts/hermes-safe/health-snapshot.sh"
else
  echo "== 6. SKIPPED Docker log rotation (run with --with-docker-restart during a maintenance window) =="
fi

echo "== DONE =="
