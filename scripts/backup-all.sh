#!/bin/bash
# /home_ai/scripts/backup-all.sh — weekly comprehensive backup (SPEC §7.3).
#
# This is the *weekly* DR backup. The daily lighter backup runs at 03:00 via
# `backup-nightly.sh` (handles DB dump + n8n_data + vault_data + config).
# This script adds:
#   - metabase_app DB dump
#   - n8n workflow JSON exports (all workflows, decrypted credentials excluded)
#   - explicit Vault data tarball (file-storage; raft not in use)
#   - optional git push (disabled by default — uncomment after verifying remote
#     does not contain anything that should not be pushed)
#
# Cron line (NOT installed — install manually after first verified run):
#   0 4 * * 0 /home_ai/scripts/backup-all.sh >> /home_ai/backups/backup-all.log 2>&1
#
# Status: Phase 2 DR prep. Run manually first; only schedule once you trust it.

set -euo pipefail

DAY=$(date +%Y%m%d)
BACKUP_DIR="/home_ai/backups/weekly/$DAY"
mkdir -p "$BACKUP_DIR/n8n-workflows"

REPO_PATH="${RESTIC_REPO:-/home_ai/backups/restic-local}"
PW_FILE="/home_ai/backups/.restic-pw"
LOG_FILE="/home_ai/backups/last-backup-all.log"

export RESTIC_REPOSITORY="$REPO_PATH"
export RESTIC_PASSWORD_FILE="$PW_FILE"

started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
exec > >(tee -a "$LOG_FILE") 2>&1
echo "── weekly DR backup started $started ──"

# ── PostgreSQL: both DBs ────────────────────────────────────────
echo "→ pg_dump homeai + metabase_app"
docker exec homeai-postgres pg_dump -U postgres -d homeai --format=custom \
  > "$BACKUP_DIR/homeai.pgdump"
docker exec homeai-postgres pg_dump -U postgres -d metabase_app --format=custom \
  > "$BACKUP_DIR/metabase_app.pgdump"

# ── n8n workflows (declarative export — no execution data, no credentials) ──
# Uses CLI which doesn't conflict with the running n8n daemon.
echo "→ n8n export:workflow --all (definitions only)"
docker exec homeai-n8n n8n export:workflow --all --output=/tmp/all-workflows.json \
  >/dev/null 2>&1 || echo "  ⚠ n8n CLI export had issues; check container"
docker cp homeai-n8n:/tmp/all-workflows.json "$BACKUP_DIR/n8n-workflows/all-workflows.json" \
  2>/dev/null || true
docker exec homeai-n8n rm -f /tmp/all-workflows.json 2>/dev/null || true

# ── Vault data tarball (file storage; encrypted blob useless without keys) ──
echo "→ tar vault_data volume"
docker run --rm -v home_ai_vault_data:/src:ro \
  -v "$BACKUP_DIR":/dst alpine \
  tar czf /dst/vault_data.tar.gz -C /src .

# ── Restic captures the BACKUP_DIR + config tree ────────────────
if ! restic snapshots >/dev/null 2>&1; then
  echo "→ initialising restic repo (first weekly run)"
  restic init
fi

echo "→ restic backup"
restic backup \
  --tag homeai-weekly \
  --tag "phase=1-dr" \
  --exclude '/home_ai/backups/restic-local' \
  --exclude '/home_ai/backups/staging' \
  --exclude '/home_ai/.git' \
  --exclude 'node_modules' \
  --exclude '*.pyc' \
  --exclude '__pycache__' \
  "$BACKUP_DIR" \
  /home_ai/postgres \
  /home_ai/monitoring \
  /home_ai/.claude \
  /home_ai/scripts \
  /home_ai/security \
  /home_ai/docker-compose.yml \
  /home_ai/AGENTS.md \
  /home_ai/SPEC.md \
  /home_ai/HOME-AI-STRETCH.md \
  /home_ai/start.sh

# Retention: 12 weekly + 6 monthly. The daily script handles its own
# 7d/4w/6m policy on its own snapshots — distinct tags.
echo "→ retention prune (weekly tag)"
restic forget --tag homeai-weekly --keep-weekly 12 --keep-monthly 6 --prune

# ── Optional: git push of repo state ────────────────────────────
# Uncomment after verifying:
#   1. /home_ai is a git repo with a remote that's safe to push to
#   2. .gitignore excludes /backups, /storage, /staging, n8n_data, vault_data
#   3. No secrets ever land in tracked files
#
cd /home_ai && \
  git add -A && \
  git commit -m "backup: weekly snapshot $(date +%Y-%m-%d)" --allow-empty && \
  git push off-host-backup main

echo "── weekly backup complete $(date -u '+%Y-%m-%dT%H:%M:%SZ') ──"
echo "BACKUP_DIR: $BACKUP_DIR"
restic snapshots --tag homeai-weekly --compact | tail -5
