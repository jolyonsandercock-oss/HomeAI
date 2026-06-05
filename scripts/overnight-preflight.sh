#!/usr/bin/env bash
# overnight-preflight.sh — collect the decisions/secrets the overnight sprint needs,
# do the actions that require YOU present (rotate the n8n Vault token, activate the
# renewer cron), and write the config the unattended run reads. Run this once, review
# the summary, then kick off the overnight run.
#
#   bash /home_ai/scripts/overnight-preflight.sh
#
# Nothing here is destructive beyond rotating the n8n token (old one is revoked) and
# installing the committed crontab snapshot. Skippable prompts default sanely.
set -euo pipefail
umask 077

readonly CONFIG="/home_ai/.claude/overnight-config.json"
readonly TOKEN_FILE="/home_ai/security/.n8n-vault-token"
readonly VAULT="homeai-vault"
ok(){ printf '\033[32m✓\033[0m %s\n' "$*"; }
info(){ printf '  %s\n' "$*"; }
hr(){ printf '\033[2m%s\033[0m\n' '────────────────────────────────────────────'; }
cleanup(){ unset VT OLD NEW; }
trap cleanup EXIT INT TERM

printf '\033[1mOvernight sprint pre-flight\033[0m\n'
hr

# ── 1. Rotate the n8n Vault token + activate the renewer cron ───────────────
echo "1) n8n Vault token rotation + renewer cron"
info "The current token was printed in chat earlier; rotating replaces it with a"
info "fresh, unexposed one and revokes the old. Also activates the 12h renewer cron."
read -rsp '   Vault admin token (hvs.…)  [Enter to SKIP rotation/cron]: ' VT; echo
if [ -n "$VT" ]; then
  if ! docker exec -e VAULT_TOKEN="$VT" "$VAULT" vault token lookup >/dev/null 2>&1; then
    echo "   ✗ token rejected by Vault — skipping rotation (fix and re-run)"; VT=""
  fi
fi
ROTATED=false; CRON=false
if [ -n "$VT" ]; then
  OLD=$(cat "$TOKEN_FILE" 2>/dev/null || true)
  NEW=$(docker exec -e VAULT_TOKEN="$VT" "$VAULT" \
        vault token create -policy=n8n-policy -period=168h -renewable=true -field=token)
  ( umask 077; printf '%s' "$NEW" > "$TOKEN_FILE" )
  bash /home_ai/scripts/install-n8n-vault-token.sh   # writes NEW into n8n credential + restarts n8n
  ROTATED=true
  if [ -n "${OLD:-}" ] && [ "$OLD" != "$NEW" ]; then
    docker exec -e VAULT_TOKEN="$VT" "$VAULT" vault token revoke "$OLD" >/dev/null 2>&1 \
      && ok "old (exposed) token revoked" || info "could not revoke old token (may already be gone)"
  fi
  # activate the renewer cron from the committed snapshot (adds the renewer, keeps everything)
  crontab /home_ai/scripts/crontab.snapshot.txt && CRON=true
  ok "renewer cron active: $(crontab -l 2>/dev/null | grep -c renew-n8n) renewer job"
else
  info "skipped — rotate later with this script; the current token still works."
fi
unset VT
hr

# ── 2. Invoice canonical-category mapping (sprint S4) ───────────────────────
echo "2) Invoice category mapping (sprint S4 — 'invoices aren't categorised' fix)"
info "Proposed mapping (pub trade: wet=drinks, dry=food):"
cat <<'MAP'
     wet_purchase        -> Beverage
     dry_purchase        -> Food
     software            -> Software
     repairs_maintenance -> Maintenance
     utilities           -> Utilities
     income              -> (excluded: not a cost)
     other               -> Other
MAP
read -rp '   Accept this mapping and run S4?  [Y/n/edit]: ' MAPANS; MAPANS=${MAPANS:-Y}
CATMAP='{"wet_purchase":"Beverage","dry_purchase":"Food","software":"Software","repairs_maintenance":"Maintenance","utilities":"Utilities","other":"Other"}'
case "$MAPANS" in
  [Yy]*) S4=true ;;
  edit*) echo "   → leave S4 out tonight; edit $CONFIG by hand and re-enable. S4 disabled."; S4=false ;;
  *)     S4=false; info "S4 (category mapping) disabled." ;;
esac
hr

# ── 3. Distillation backfill budget (sprint S1) ────────────────────────────
echo "3) Cultural-memory dossier backfill (sprint S1)"
info "862 dossiers left to distil via Sonnet. Est. \$15–30 one-time."
read -rp '   Backfill USD cap  [30]: ' BUD; BUD=${BUD:-30}
read -rp '   Per-run batch size (counterparties per loop)  [25]: ' BATCH; BATCH=${BATCH:-25}
hr

# ── 4. Which sprints to run ────────────────────────────────────────────────
echo "4) Sprints to run tonight"
info "S1=dossier backfill  S2=observability hardening  S3=invoice-DWD design spec  S4=category mapping"
DEFSEL="S1 S2 S3"; [ "$S4" = true ] && DEFSEL="S1 S2 S3 S4"
read -rp "   Sprints  [$DEFSEL]: " SEL; SEL=${SEL:-$DEFSEL}
hr

# ── 5. Write the config the overnight run reads ────────────────────────────
python3 - "$CONFIG" "$SEL" "$BUD" "$BATCH" "$CATMAP" "$ROTATED" "$CRON" <<'PY'
import json, sys, datetime
cfg=dict(
  generated_at=datetime.datetime.utcnow().isoformat()+"Z",
  sprints=sys.argv[2].split(),
  backfill_budget_usd=float(sys.argv[3]),
  backfill_batch=int(sys.argv[4]),
  category_map=json.loads(sys.argv[5]),
  token_rotated=(sys.argv[6]=="true"),
  cron_activated=(sys.argv[7]=="true"),
  guardrails=dict(
    no_pipeline_activation=True, no_n8n_workflow_surgery=True,
    stop_on_unrecovered_error=True, owner_realm_only=True),
)
open(sys.argv[1],"w").write(json.dumps(cfg, indent=2))
print(json.dumps(cfg, indent=2))
PY
ok "config written to $CONFIG"
hr
printf '\033[1mPre-flight complete.\033[0m  Token rotated: %s · cron: %s · sprints: %s\n' "$ROTATED" "$CRON" "$SEL"
echo "Next: kick off the overnight run against docs/superpowers/plans/2026-06-05-overnight-sprint-U243.md"
