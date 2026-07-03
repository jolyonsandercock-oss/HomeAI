#!/usr/bin/env bash
# jo-walkthrough-20260703.sh — interactive walkthrough for the four owner-only
# actions from the 2026-07-03 morning brief:
#
#   Step 1  Vault ACL: grant the vault-agent AppRole read on secret/data/deepseek
#   Step 2  Rotate the DeepSeek API key (old one appeared in an agent transcript)
#           and store the NEW key in Vault
#   Step 3  Render + publish: restart vault-agent, recreate litellm with its new
#           loopback port 127.0.0.1:8771, verify the deepseek route end-to-end
#   Step 4  Repoint Hermes (~/.hermes/auth.json) at the gateway, verify
#   Step 5  Review the hermes-sentinel baseline diff (pending since 23 Jun) and
#           re-anchor if legitimate
#
# Run it in a real terminal:   bash /home_ai/scripts/jo-walkthrough-20260703.sh
# Every step asks before doing anything; say n to skip a step. Secrets are read
# with read -s and never echoed or written to disk outside Vault.
set -uo pipefail

C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
say()  { printf '%s\n' "${C_B}$*${C_0}"; }
ok()   { printf '%s\n' "${C_G}✓ $*${C_0}"; }
warn() { printf '%s\n' "${C_Y}! $*${C_0}"; }
fail() { printf '%s\n' "${C_R}✗ $*${C_0}"; }
ask()  { local a; read -r -p "$1 [y/n] " a; [[ "$a" == y* || "$a" == Y* ]]; }

MASTER_KEY="$(grep -E '^LITELLM_MASTER_KEY=' /home_ai/.env 2>/dev/null | cut -d= -f2-)"
MASTER_KEY="${MASTER_KEY:-sk-homeai-internal}"

vaultc() { docker exec -e VAULT_TOKEN="$ADMIN_TOKEN" homeai-vault vault "$@"; }

# ── preflight ────────────────────────────────────────────────────────────────
say "── Preflight"
for c in homeai-vault homeai-vault-agent homeai-litellm homeai-presidio; do
  docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true \
    && ok "$c running" || { fail "$c NOT running — fix before continuing"; exit 1; }
done
if docker exec homeai-vault vault status 2>/dev/null | grep -q "Sealed.*false"; then
  ok "vault unsealed"
else
  fail "vault appears sealed — run the unseal path first"; exit 1
fi

ADMIN_TOKEN="$(grep -E '^VAULT_TOKEN=' /home_ai/.env 2>/dev/null | cut -d= -f2-)"
if [ -z "$ADMIN_TOKEN" ]; then
  read -r -s -p "Paste an admin VAULT_TOKEN (input hidden): " ADMIN_TOKEN; echo
fi
vaultc token lookup >/dev/null 2>&1 && ok "admin token valid" \
  || { fail "token rejected by Vault"; exit 1; }

# ── Step 1: ACL grant ────────────────────────────────────────────────────────
echo; say "── Step 1: grant vault-agent AppRole read on secret/data/deepseek"
say "   Why: the litellm gateway needs the DeepSeek key rendered to /run/secrets/"
say "   so Hermes's DeepSeek traffic can go through Presidio redaction + cost logging."
if ask "Do step 1?"; then
  ROLE="$(vaultc list -format=yaml auth/approle/role 2>/dev/null | sed -n 's/^- //p' | head -1)"
  [ -n "$ROLE" ] || { fail "no AppRole role found under auth/approle/role"; exit 1; }
  POLICY="$(vaultc read -field=token_policies "auth/approle/role/$ROLE" 2>/dev/null | tr -d '[]' | tr ',' '\n' | grep -v '^default$' | head -1 | xargs)"
  [ -n "$POLICY" ] || { fail "could not resolve the role's policy"; exit 1; }
  say "   AppRole role: $ROLE   policy: $POLICY — current policy:"
  vaultc policy read "$POLICY" | sed 's/^/   │ /'
  if vaultc policy read "$POLICY" | grep -q 'secret/data/deepseek'; then
    ok "policy already grants secret/data/deepseek — nothing to do"
  elif ask "Append read on secret/data/deepseek to policy '$POLICY'?"; then
    vaultc policy read "$POLICY" > /tmp/jo-policy.hcl
    cat >> /tmp/jo-policy.hcl <<'EOF'

# 2026-07-03 (Jo, walkthrough): litellm deepseek route — vault-agent renders
# /run/secrets/deepseek-api-key for the Hermes egress gateway
path "secret/data/deepseek" {
  capabilities = ["read"]
}
EOF
    docker cp /tmp/jo-policy.hcl homeai-vault:/tmp/jo-policy.hcl && rm -f /tmp/jo-policy.hcl
    vaultc policy write "$POLICY" /tmp/jo-policy.hcl \
      && ok "policy '$POLICY' updated" || fail "policy write failed"
    docker exec homeai-vault rm -f /tmp/jo-policy.hcl
  fi
fi

# ── Step 2: rotate the DeepSeek key ──────────────────────────────────────────
echo; say "── Step 2: rotate the DeepSeek API key"
say "   Why: the old key appeared in an agent transcript last night — treat as exposed."
say "   1. Open https://platform.deepseek.com → API Keys"
say "   2. Create a NEW key (name it e.g. homeai-gateway-2026-07)"
say "   3. Do NOT delete the old key yet — Hermes still uses it until step 4."
if ask "Have the new key ready — store it in Vault now?"; then
  read -r -s -p "Paste the NEW DeepSeek key (input hidden): " NEWKEY; echo
  [ -n "$NEWKEY" ] || { fail "empty — skipping"; NEWKEY=""; }
  if [ -n "$NEWKEY" ]; then
    docker exec -i -e VAULT_TOKEN="$ADMIN_TOKEN" -e NK="$NEWKEY" homeai-vault \
      sh -c 'vault kv put secret/deepseek api_key="$NK"' >/dev/null \
      && ok "stored at secret/deepseek (api_key)" || fail "vault kv put failed"
    unset NEWKEY
  fi
fi

# ── Step 3: render + publish + verify the gateway ────────────────────────────
echo; say "── Step 3: restart vault-agent (renders the key) + recreate litellm (publishes 127.0.0.1:8771)"
if ask "Do step 3?"; then
  docker restart homeai-vault-agent >/dev/null && ok "vault-agent restarted"
  for i in $(seq 1 15); do
    docker exec homeai-vault-agent sh -c 'test -s /run/secrets/deepseek-api-key' 2>/dev/null && break
    sleep 2
  done
  if docker exec homeai-vault-agent sh -c 'test -s /run/secrets/deepseek-api-key'; then
    ok "/run/secrets/deepseek-api-key rendered (ACL grant works)"
  else
    fail "key file not rendered after 30s — check step 1 policy and step 2 secret"; exit 1
  fi
  ( cd /home_ai && docker compose up -d --force-recreate homeai-litellm ) \
    && ok "litellm recreated with port publish" || { fail "compose recreate failed"; exit 1; }
  sleep 5
  CODE=$(curl -s -o /tmp/jo-models.json -w '%{http_code}' \
        -H "Authorization: Bearer $MASTER_KEY" http://127.0.0.1:8771/v1/models) || CODE=000
  if [ "$CODE" = "200" ] && grep -q 'deepseek-v4-pro' /tmp/jo-models.json; then
    ok "gateway answers on 127.0.0.1:8771 and lists deepseek-v4-pro"
  else
    fail "gateway check failed (HTTP $CODE) — see docker logs homeai-litellm"; exit 1
  fi
  rm -f /tmp/jo-models.json
  say "   Live round-trip through Presidio + DeepSeek (1 short completion):"
  curl -s -m 60 http://127.0.0.1:8771/v1/chat/completions \
    -H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4-pro","max_tokens":10,"messages":[{"role":"user","content":"Reply with exactly: GATEWAY OK"}]}' \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("   →", d["choices"][0]["message"]["content"].strip())' \
    && ok "end-to-end DeepSeek call through the gateway works" \
    || fail "completion failed — new key valid? see docker logs homeai-litellm"
fi

# ── Step 4: repoint Hermes ───────────────────────────────────────────────────
echo; say "── Step 4: repoint Hermes's deepseek provider at the gateway"
AUTH=/home/joly/.hermes/auth.json
if ask "Do step 4?"; then
  BK="$AUTH.pre-gateway-$(date +%Y%m%d%H%M)"
  cp "$AUTH" "$BK" && ok "backup: $BK"
  MK="$MASTER_KEY" python3 - "$AUTH" <<'PY'
import json, os, sys
p = sys.argv[1]; mk = os.environ["MK"]
d = json.load(open(p))
GW = "http://127.0.0.1:8771/v1"
n = 0
prov = d.get("providers", {}).get("deepseek")
if prov:
    prov["inference_base_url"] = GW; prov["api_key"] = mk; n += 1
for c in d.get("credential_pool", {}).get("deepseek", []):
    c["base_url"] = GW; c["access_token"] = mk; n += 1
json.dump(d, open(p, "w"), indent=1)
print(f"   repointed {n} deepseek entries -> {GW}")
PY
  ok "auth.json repointed (rollback: cp $BK $AUTH)"
  say "   Now send Hermes a quick test message that routes to deepseek."
  say "   When it answers, delete the OLD key at platform.deepseek.com."
  ask "Hermes verified + old key deleted?" && ok "rotation complete — old key dead" \
    || warn "remember to delete the old key once Hermes is verified"
fi

# ── Step 5: hermes-sentinel baseline ─────────────────────────────────────────
echo; say "── Step 5: review the hermes-sentinel drift (detected since 23 Jun)"
say "   The sentinel found Hermes's skills bundle + user profile changed vs the"
say "   approved baseline. Review the diff — if it's all changes YOU made (or the"
say "   step-4 repoint just now), re-anchor. If anything looks foreign, STOP."
if ask "Show the latest sentinel diff?"; then
  grep -E '^\+|^-' /home_ai/logs/hermes-sentinel.log | tail -30 | sed 's/^/   /'
  if ask "All legitimate — accept current state as the new baseline?"; then
    bash /home_ai/scripts/hermes-sentinel.sh --baseline \
      && ok "baseline re-anchored" || fail "re-anchor failed"
    ( cd /home_ai && git add security/hermes-sentinel-baseline.json \
      && git commit -q -m "security(sentinel): re-anchor hermes baseline (Jo-reviewed 2026-07-03)" ) \
      && ok "baseline committed" || warn "commit skipped (check git status)"
  fi
fi

echo; say "── Done. The next sentinel cycle (every 30 min) should log 'heartbeat (clean)'."
