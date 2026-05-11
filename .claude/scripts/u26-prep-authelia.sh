#!/bin/bash
# /home_ai/.claude/scripts/u26-prep-authelia.sh
#
# Pre-flight for /home_ai/scripts/authelia-bootstrap.sh — which is excellent
# but needs the security/authelia config dir writable by you (not root).
# Plus a quick sanity check that the config layout exists.
#
# Run as your normal user. Calls sudo only for the chown step. After this
# completes, run:
#
#     bash /home_ai/scripts/authelia-bootstrap.sh
#
# …which handles the actual secret generation + admin user creation.

set -uo pipefail
GREEN='\033[0;32m'; YEL='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

CONFIG_DIR=/home_ai/security/authelia-v2
ME=$(whoami)
echo "── U26: Authelia pre-flight ──"

# 1. Detect existing dir
if [[ ! -d "$CONFIG_DIR" ]]; then
  echo -e "${RED}✗${NC} $CONFIG_DIR doesn't exist. Manual fix required:"
  echo "    sudo mkdir -p $CONFIG_DIR"
  echo "    Then copy a base configuration.yml + users_database.yml.template into it."
  exit 1
fi

# 2. Make sure we own the dir (sudo only for this one step)
owner=$(stat -c '%U' "$CONFIG_DIR")
if [[ "$owner" != "$ME" ]]; then
  echo -e "${YEL}!${NC} $CONFIG_DIR is owned by $owner — need sudo to chown to $ME"
  sudo chown -R "$ME:$ME" "$CONFIG_DIR" || { echo -e "${RED}✗${NC} chown failed"; exit 1; }
  echo -e "${GREEN}✓${NC} chowned $CONFIG_DIR → $ME"
else
  echo -e "${GREEN}✓${NC} $CONFIG_DIR already owned by $ME"
fi

# 3. Detect required template files
for f in configuration.yml users_database.yml.template; do
  if [[ -f "$CONFIG_DIR/$f" ]]; then
    echo -e "${GREEN}✓${NC} $CONFIG_DIR/$f present"
  else
    echo -e "${RED}✗${NC} $CONFIG_DIR/$f missing — authelia-bootstrap.sh will fail without it"
    exit 1
  fi
done

# 4. Check that the existing config has the SECRET placeholders the bootstrap
#    script expects to substitute
if grep -qE "^\s*encryption_key:\s*''" "$CONFIG_DIR/configuration.yml" &&
   grep -qE "^\s*jwt_secret:\s*''" "$CONFIG_DIR/configuration.yml"; then
  echo -e "${GREEN}✓${NC} config has empty encryption_key + jwt_secret placeholders (ready for substitution)"
else
  echo -e "${YEL}!${NC} secrets may already be filled — authelia-bootstrap.sh is non-destructive"
  echo "    but won't overwrite. If you need fresh secrets, edit configuration.yml first."
fi

# 5. Check Vault is reachable and unsealed (bootstrap stashes secrets there)
if docker exec homeai-vault vault status 2>/dev/null | grep -q "Sealed.*false"; then
  echo -e "${GREEN}✓${NC} Vault unsealed — bootstrap will stash secrets to secret/authelia/*"
else
  echo -e "${RED}✗${NC} Vault is sealed. Run ./start.sh or u13-vault-unseal.sh first."
  exit 1
fi

# 6. Check docker-compose authelia entry exists
if grep -qE "^\s*authelia:" /home_ai/docker-compose.yml; then
  echo -e "${GREEN}✓${NC} docker-compose has authelia entry"
else
  echo -e "${RED}✗${NC} no authelia block in docker-compose.yml — add it before bootstrapping"
  exit 1
fi

echo
echo -e "${GREEN}── pre-flight passed ──${NC}"
echo
echo "Next, run the actual bootstrap (it'll prompt for password + Vault token):"
echo "    bash /home_ai/scripts/authelia-bootstrap.sh"
echo
echo "After bootstrap, bring up the container:"
echo "    docker compose --profile phase2 up -d authelia"
echo
echo "Then wire Caddy /auth/ → homeai-authelia:9091 (uncomment the placeholder"
echo "block in /home_ai/config/caddy/Caddyfile — it's already there as a 503)."
