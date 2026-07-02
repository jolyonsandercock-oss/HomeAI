#!/usr/bin/env bash
# set-vercel-creds.sh — interactive helper to put Vercel credentials in Vault.
#
# Stores secret/vercel = { token, org_id, project_id }, after resolving
# human-friendly names to real IDs via api.vercel.com.
#
# Token is NEVER echoed back. Re-runnable.

set -euo pipefail

# ── Find a live Vault token ────────────────────────────────────────────────
for c in homeai-critical-listener homeai-n8n homeai-google-fetch; do
  VAULT_TOKEN=$(docker inspect "$c" --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
                | grep '^VAULT_TOKEN=' | cut -d= -f2-)
  [ -n "$VAULT_TOKEN" ] && break
done
[ -z "$VAULT_TOKEN" ] && { echo "VAULT_TOKEN not found in any container env"; exit 1; }
export VAULT_TOKEN

# ── Existing values? ───────────────────────────────────────────────────────
EXISTING=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -format=json secret/vercel 2>/dev/null) || EXISTING=""
existing_token=""; existing_org=""; existing_project=""
if [ -n "$EXISTING" ]; then
  existing_token=$(echo "$EXISTING"   | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('token',''))")
  existing_org=$(echo "$EXISTING"     | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('org_id',''))")
  existing_project=$(echo "$EXISTING" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('project_id',''))")
fi

mask() {
  # Print "set" if the value is non-empty, otherwise "not set". Never the value itself.
  if [ -n "$1" ]; then echo "set"; else echo "not set"; fi
}

cat <<EOF
── Vercel credential setup ──────────────────────────────────────────────────

This stores your Vercel info in Vault at secret/vercel, then runs deploy.sh.
Nothing is echoed back to the screen.

You need (in order):

  1. TOKEN     — required. https://vercel.com/account/tokens
                 (currently: $(mask "$existing_token"))

  2. TEAM      — required if your Vercel account is on a team plan.
                 You can paste either the team SLUG (e.g. homeai) or
                 the full team ID (team_xxxx). The script resolves it.
                 (currently: $(mask "$existing_org"))

  3. PROJECT   — required. You can paste either the project NAME (e.g.
                 homeai-frontend) or the full project ID (prj_xxxx).
                 If a project with that name doesn't exist in the team,
                 the script offers to create it.
                 (currently: $(mask "$existing_project"))

Press enter on any prompt to keep the existing value.

EOF

# ── 1. Token ───────────────────────────────────────────────────────────────
read -r -s -p "VERCEL TOKEN (hidden) : " new_token
echo
token="${new_token:-$existing_token}"
if [ -z "$token" ]; then
  echo "❌ No token provided and none existed previously. Aborting."
  exit 1
fi

# Validate token
echo "── Validating token…"
USER_JSON=$(curl -s -H "Authorization: Bearer $token" https://api.vercel.com/v2/user)
if echo "$USER_JSON" | grep -q '"error"'; then
  echo "❌ Token rejected. Response:"
  echo "$USER_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('error',d))"
  exit 1
fi
USER_EMAIL=$(echo "$USER_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('user',{}).get('email','?'))")
USER_USERNAME=$(echo "$USER_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('user',{}).get('username','?'))")
echo "✓ Token works — Vercel user: $USER_USERNAME <$USER_EMAIL>"

# ── 2. Team — accept slug OR id ────────────────────────────────────────────
read -r -p "TEAM SLUG or ID (blank = personal, '?' to list) : " new_org
new_org="${new_org:-$existing_org}"
org=""
if [ -n "$new_org" ]; then
  if [ "$new_org" = "?" ]; then
    echo "── Teams visible to this token:"
    TEAMS_JSON=$(curl -s -H "Authorization: Bearer $token" "https://api.vercel.com/v2/teams")
    echo "$TEAMS_JSON" | python3 -c "
import json,sys
teams = json.load(sys.stdin).get('teams', [])
for t in teams:
    print(f\"  slug={t['slug']:20s}  id={t['id']:30s}  name={t.get('name','?')}\")
"
    read -r -p "Re-enter team slug or id : " new_org
  fi
  if [[ "$new_org" =~ ^team_ ]]; then
    org="$new_org"
    NAME=$(curl -s -H "Authorization: Bearer $token" "https://api.vercel.com/v2/teams/$org" \
           | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('name','?'))" 2>/dev/null)
    echo "✓ Team: $NAME ($org)"
  else
    # Treat as slug — resolve via listing
    TEAMS_JSON=$(curl -s -H "Authorization: Bearer $token" "https://api.vercel.com/v2/teams")
    org=$(echo "$TEAMS_JSON" | python3 -c "
import json, sys, os
slug = os.environ['SLUG'].lower()
for t in json.load(sys.stdin).get('teams', []):
    if t['slug'].lower() == slug:
        print(t['id']); break
" SLUG="$new_org" 2>/dev/null || true)
    SLUG="$new_org" org=$(echo "$TEAMS_JSON" | SLUG="$new_org" python3 -c "
import json, sys, os
slug = os.environ['SLUG'].lower()
for t in json.load(sys.stdin).get('teams', []):
    if t['slug'].lower() == slug:
        print(t['id']); break
")
    if [ -z "$org" ]; then
      echo "⚠ No team found with slug '$new_org'. Run again and enter ? to list."
      exit 1
    fi
    echo "✓ Team slug '$new_org' → $org"
  fi
fi

# ── 3. Project — accept name OR id ─────────────────────────────────────────
read -r -p "PROJECT NAME or ID : " new_project
new_project="${new_project:-$existing_project}"
project=""
if [ -n "$new_project" ]; then
  TEAM_QS=""
  [ -n "$org" ] && TEAM_QS="?teamId=$org"
  if [[ "$new_project" =~ ^prj_ ]]; then
    project="$new_project"
    NAME=$(curl -s -H "Authorization: Bearer $token" "https://api.vercel.com/v9/projects/$project$TEAM_QS" \
           | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('name','?'))" 2>/dev/null)
    echo "✓ Project: $NAME ($project)"
  else
    # Try resolve by name
    LIST_JSON=$(curl -s -H "Authorization: Bearer $token" "https://api.vercel.com/v9/projects$TEAM_QS&limit=100" 2>/dev/null \
                || curl -s -H "Authorization: Bearer $token" "https://api.vercel.com/v9/projects?limit=100")
    project=$(NAME_LOWER="$new_project" python3 -c "
import json, sys, os
name = os.environ['NAME_LOWER'].lower()
data = json.load(sys.stdin)
for p in (data.get('projects') or []):
    if p.get('name','').lower() == name:
        print(p['id']); break
" <<< "$LIST_JSON" 2>/dev/null || true)
    if [ -z "$project" ]; then
      echo "── No project named '$new_project' found."
      read -r -p "Create it now? [Y/n] " create
      create="${create:-Y}"
      if [[ "$create" =~ ^[Yy] ]]; then
        CREATE_JSON=$(curl -s -X POST \
          -H "Authorization: Bearer $token" \
          -H "Content-Type: application/json" \
          -d "{\"name\":\"$new_project\",\"framework\":\"nextjs\"}" \
          "https://api.vercel.com/v10/projects$TEAM_QS")
        project=$(echo "$CREATE_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('id',''))")
        if [ -z "$project" ]; then
          echo "❌ Could not create project. Response:"
          echo "$CREATE_JSON" | python3 -m json.tool | head -20
          exit 1
        fi
        echo "✓ Created project: $new_project ($project)"
      else
        echo "Aborted — no project to deploy to."
        exit 1
      fi
    else
      echo "✓ Project '$new_project' → $project"
    fi
  fi
fi

# ── Write to Vault ─────────────────────────────────────────────────────────
echo
echo "── Writing to Vault at secret/vercel"
ARGS=( "token=$token" )
[ -n "$org" ]     && ARGS+=( "org_id=$org" )
[ -n "$project" ] && ARGS+=( "project_id=$project" )

docker exec -e VAULT_TOKEN homeai-vault vault kv put secret/vercel "${ARGS[@]}" >/dev/null
echo "✓ Stored. (token hidden from output)"

# Set the Postgres-readonly env on the Vercel project too — the deploy needs it.
if [ -n "$project" ]; then
  RO_PASSWORD=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -field=homeai_readonly secret/postgres-roles 2>/dev/null || echo "")
  if [ -n "$RO_PASSWORD" ]; then
    echo "── Setting Vercel env POSTGRES_READONLY_URL on the project…"
    # Caveat: Postgres on home network can't be reached from Vercel directly.
    # This is a placeholder. Real prod needs Tailscale Funnel or a public proxy.
    # For now we set it to a Tailscale-funnel pattern Jo can update later.
    TUNNEL_URL="postgresql://homeai_readonly:$RO_PASSWORD@home-ai.local:5432/homeai"
    TEAM_QS=""; [ -n "$org" ] && TEAM_QS="?teamId=$org"
    ENV_RESPONSE=$(curl -s -X POST \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "{\"key\":\"POSTGRES_READONLY_URL\",\"value\":\"$TUNNEL_URL\",\"type\":\"encrypted\",\"target\":[\"production\",\"preview\",\"development\"]}" \
      "https://api.vercel.com/v10/projects/$project/env$TEAM_QS")
    if echo "$ENV_RESPONSE" | grep -q 'already exists\|"error"'; then
      echo "  (env var already set or error — Vercel will use whatever's in the project. Update via dashboard if needed.)"
    else
      echo "✓ POSTGRES_READONLY_URL set on Vercel project."
      echo "  ⚠ value points to homeai-postgres on the home network. Vercel can't reach"
      echo "    that directly — set up Tailscale Funnel or a public Postgres proxy first."
    fi
  fi
fi

# ── Run deploy ─────────────────────────────────────────────────────────────
echo
read -r -p "Run deploy.sh now? [Y/n] " go
go="${go:-Y}"
if [[ "$go" =~ ^[Yy] ]]; then
  exec /home_ai/services/homeai-frontend/deploy.sh
else
  echo "Skipped — run /home_ai/services/homeai-frontend/deploy.sh whenever."
fi
