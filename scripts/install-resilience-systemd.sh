#!/usr/bin/env bash
# Run with sudo. Installs the self-healing supervisor + cron-guard as systemd
# timers (survive crontab wipes AND reboots — unlike cron). U240 P1 durable layer.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

cat > /etc/systemd/system/homeai-supervisor.service <<UNIT
[Unit]
Description=Home AI self-healing supervisor (selftest + safe auto-repair + page)
After=docker.service
[Service]
Type=oneshot
User=joly
ExecStart=/usr/bin/bash /home_ai/scripts/u241-supervisor.sh
UNIT
cat > /etc/systemd/system/homeai-supervisor.timer <<UNIT
[Unit]
Description=Run Home AI supervisor every 10 min
[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
Persistent=true
[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/homeai-cron-guard.service <<UNIT
[Unit]
Description=Home AI cron-guard (reinstall crontab from snapshot if wiped)
[Service]
Type=oneshot
ExecStart=/usr/bin/bash /home_ai/scripts/homeai-cron-guard.sh
UNIT
cat > /etc/systemd/system/homeai-cron-guard.timer <<UNIT
[Unit]
Description=Run Home AI cron-guard every 15 min
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now homeai-supervisor.timer homeai-cron-guard.timer
echo "installed + enabled:"; systemctl list-timers homeai-supervisor.timer homeai-cron-guard.timer --no-pager
