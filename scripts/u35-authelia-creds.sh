#!/bin/bash
# /home_ai/scripts/u35-authelia-creds.sh
#
# Print the Authelia admin credentials for first-login TOTP enrolment.
# Usage:  bash /home_ai/scripts/u35-authelia-creds.sh
#
# Reads from Vault — no secrets on disk. Output is shown ONCE.

set -euo pipefail

VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
if [[ -z "$VAULT_TOKEN" ]]; then
  echo "✗ Could not harvest VAULT_TOKEN from homeai-google-fetch" >&2
  exit 1
fi

PW=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
       vault kv get -field=password secret/authelia/admin_initial 2>/dev/null)
if [[ -z "$PW" ]]; then
  echo "✗ secret/authelia/admin_initial not found in Vault" >&2
  exit 1
fi

cat <<EOF

╭─ Authelia first-login credentials ──────────────────────────╮
│                                                             │
│  Portal URL: http://100.104.82.53/auth/                     │
│              (Tailscale-fenced — must be on the tailnet)    │
│                                                             │
│  Username:   jo                                             │
│  Password:   $PW
│                                                             │
│  After first login:                                         │
│   1. Authelia will redirect to TOTP enrolment.              │
│   2. Scan the QR code with your authenticator app           │
│      (Google Authenticator, Authy, etc).                    │
│   3. Save the recovery codes somewhere safe.                │
│   4. Change the password from this initial random one to    │
│      something memorable.                                   │
│                                                             │
│  Note: full forward_auth on /dashboard, /pub, etc is NOT    │
│  yet enabled — needs a proper FQDN (via tailscale cert)     │
│  before session cookies work. See Caddyfile for details.    │
│                                                             │
╰─────────────────────────────────────────────────────────────╯

EOF

unset VAULT_TOKEN PW
