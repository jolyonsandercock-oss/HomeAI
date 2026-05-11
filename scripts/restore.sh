#!/bin/bash
# /home_ai/scripts/restore.sh — restore Home AI data on new hardware.
#
# Run AFTER bootstrap.sh + AFTER ./start.sh has brought services up.
# Vault must already be unsealed with offline keys; this script does NOT
# unseal Vault (that requires interactive key entry).
#
# Source can be:
#   1. A backup-all.sh staging dir on disk (contains pgdumps + n8n exports + vault tar)
#   2. A restic snapshot ID — script extracts to a tempdir then proceeds
#
# Usage:
#   restore.sh /home_ai/backups/weekly/20260512        # staging dir
#   restore.sh restic <snapshot-id>                    # restore from restic
#   restore.sh restic latest                           # latest weekly snapshot
#   restore.sh --dry-run /path/to/backup               # show without applying
#
# DESTRUCTIVE — overwrites the homeai + metabase_app databases. Confirms
# before proceeding unless --yes is passed.

set -euo pipefail

DRY_RUN=false
ASSUME_YES=false
ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    *)         ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [--dry-run] [--yes] (BACKUP_DIR | restic SNAPSHOT_ID)"
  exit 1
fi

run() { if $DRY_RUN; then echo "  [dry-run] $*"; else "$@"; fi; }

confirm() {
  $ASSUME_YES && return 0
  $DRY_RUN    && return 0
  read -rp "$1 (yes/NO): " ans
  [[ "$ans" == "yes" ]]
}

# ── Resolve source ──────────────────────────────────────────────
SOURCE=""
TEMP_RESTORE=""
cleanup() { [[ -n "${TEMP_RESTORE:-}" && -d "$TEMP_RESTORE" ]] && rm -rf "$TEMP_RESTORE"; }
trap cleanup EXIT

if [[ "$1" == "restic" ]]; then
  SNAP="${2:?Usage: restore.sh restic SNAPSHOT_ID|latest}"
  TEMP_RESTORE=$(mktemp -d -t homeai-restore-XXXXXX)
  echo "→ restoring restic snapshot $SNAP to $TEMP_RESTORE"
  export RESTIC_REPOSITORY="${RESTIC_REPO:-/home_ai/backups/restic-local}"
  export RESTIC_PASSWORD_FILE="/home_ai/backups/.restic-pw"
  if [[ "$SNAP" == "latest" ]]; then
    SNAP=$(restic snapshots --tag homeai-weekly --json 2>/dev/null \
            | jq -r 'sort_by(.time) | last | .id // empty')
    [[ -z "$SNAP" ]] && { echo "✗ no homeai-weekly snapshots found"; exit 1; }
    echo "  using: $SNAP"
  fi
  run restic restore "$SNAP" --target "$TEMP_RESTORE"
  # backup-all.sh staging dirs land under home_ai/backups/weekly/<DATE>/
  SOURCE=$(find "$TEMP_RESTORE/home_ai/backups/weekly" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  [[ -z "$SOURCE" ]] && { echo "✗ couldn't locate backup-all staging dir inside snapshot"; exit 1; }
else
  SOURCE="$1"
fi

if ! [[ -d "$SOURCE" ]]; then
  echo "✗ source not found: $SOURCE"
  exit 1
fi

echo "── Home AI restore ($($DRY_RUN && echo 'dry-run' || echo 'live')) ──"
echo "source: $SOURCE"
echo

# ── Sanity check the source has what we expect ─────────────────
HAS_HOMEAI=false; [[ -f "$SOURCE/homeai.pgdump"     ]] && HAS_HOMEAI=true
HAS_META=false;   [[ -f "$SOURCE/metabase_app.pgdump" ]] && HAS_META=true
HAS_VAULT=false;  [[ -f "$SOURCE/vault_data.tar.gz"  ]] && HAS_VAULT=true
HAS_N8N=false;    [[ -f "$SOURCE/n8n-workflows/all-workflows.json" ]] && HAS_N8N=true

echo "found in source:"
echo "  homeai.pgdump       : $($HAS_HOMEAI && echo yes || echo NO)"
echo "  metabase_app.pgdump : $($HAS_META   && echo yes || echo NO)"
echo "  vault_data.tar.gz   : $($HAS_VAULT  && echo yes || echo NO)"
echo "  n8n workflows       : $($HAS_N8N    && echo yes || echo NO)"
echo

if ! $HAS_HOMEAI; then
  echo "✗ refusing to restore — homeai.pgdump missing from source"
  exit 1
fi

confirm "this will OVERWRITE homeai DB (and optionally metabase_app + n8n + vault)" || exit 1

# ── 1. PostgreSQL homeai ───────────────────────────────────────
echo "→ restore homeai DB"
run docker exec -i homeai-postgres psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS homeai;"
run docker exec -i homeai-postgres psql -U postgres -d postgres -c "CREATE DATABASE homeai;"
if ! $DRY_RUN; then
  docker exec -i homeai-postgres pg_restore -U postgres -d homeai --no-owner < "$SOURCE/homeai.pgdump"
else
  echo "  [dry-run] pg_restore homeai.pgdump"
fi

# ── 2. metabase_app (only if present) ──────────────────────────
if $HAS_META; then
  echo "→ restore metabase_app DB"
  run docker exec -i homeai-postgres psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS metabase_app;"
  run docker exec -i homeai-postgres psql -U postgres -d postgres -c "CREATE DATABASE metabase_app OWNER metabase_app;"
  if ! $DRY_RUN; then
    docker exec -i homeai-postgres pg_restore -U postgres -d metabase_app --no-owner < "$SOURCE/metabase_app.pgdump"
  fi
fi

# ── 3. n8n workflows ───────────────────────────────────────────
if $HAS_N8N; then
  echo "→ restore n8n workflows"
  run docker cp "$SOURCE/n8n-workflows/all-workflows.json" homeai-n8n:/tmp/all-workflows.json
  if ! $DRY_RUN; then
    docker exec homeai-n8n n8n import:workflow --input=/tmp/all-workflows.json 2>&1 | tail -3
    docker exec homeai-n8n rm -f /tmp/all-workflows.json
  fi
fi

# ── 4. vault_data tar ──────────────────────────────────────────
# This is delicate: replacing the running Vault's data dir while the
# container is up will confuse it. Better: stop, replace, start.
if $HAS_VAULT; then
  echo "→ restore vault_data (will stop+start homeai-vault)"
  if confirm "stop homeai-vault, restore data, start it again?"; then
    run docker stop homeai-vault
    run docker run --rm \
      -v home_ai_vault_data:/dst \
      -v "$SOURCE":/src:ro \
      alpine sh -c 'rm -rf /dst/* /dst/.??* && tar xzf /src/vault_data.tar.gz -C /dst'
    run docker start homeai-vault
    echo "  ⚠ Vault is sealed after restore — re-unseal with offline keys"
  else
    echo "  (skipped vault_data restore)"
  fi
fi

echo
echo "── restore complete ──"
echo
echo "Manual steps remaining:"
echo "  1. Unseal Vault if it was restored: 3× vault operator unseal <key>"
echo "  2. /verify-phase1   # check system health"
echo "  3. Re-run any OAuth flows whose tokens have expired"
echo "  4. Pull Ollama models if Ollama volume wasn't restored:"
echo "     docker exec homeai-ollama ollama pull qwen2.5:7b"
