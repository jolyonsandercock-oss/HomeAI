#!/usr/bin/env bash
# u62-paperless-bootstrap.sh — one-shot: create paperless DB on the existing
# postgres, write secrets to Vault, prep storage dirs. Then `docker compose
# up -d paperless`.

set -euo pipefail

VT=$(docker inspect homeai-bot-responder --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)

# Generate secrets if not present
gen() { python3 -c "import secrets; print(secrets.token_urlsafe($1))"; }

if ! docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get secret/paperless >/dev/null 2>&1; then
    PL_DB_PW=$(gen 32)
    PL_ADMIN_PW=$(gen 24)
    PL_SECRET=$(gen 50)
    docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv put secret/paperless \
        db_password="$PL_DB_PW" admin_password="$PL_ADMIN_PW" secret_key="$PL_SECRET"
    echo "✓ wrote secret/paperless"
else
    PL_DB_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=db_password secret/paperless)
    PL_ADMIN_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=admin_password secret/paperless)
    PL_SECRET=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=secret_key secret/paperless)
    echo "✓ secret/paperless already exists, using stored values"
fi

# Create paperless db + role on existing postgres
docker exec -i homeai-postgres psql -U postgres -d postgres <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'paperless') THEN
        CREATE ROLE paperless LOGIN PASSWORD '$PL_DB_PW';
    ELSE
        ALTER ROLE paperless WITH PASSWORD '$PL_DB_PW';
    END IF;
END \$\$;
SELECT 'create db if absent' AS step
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'paperless') \gexec
SQL

# Create the database outside the DO block (CREATE DATABASE can't run inside)
EXISTS=$(docker exec -i homeai-postgres psql -U postgres -d postgres -A -t -c "SELECT 1 FROM pg_database WHERE datname='paperless'")
if [[ -z "$EXISTS" ]]; then
    docker exec -i homeai-postgres psql -U postgres -d postgres -c "CREATE DATABASE paperless OWNER paperless;"
    echo "✓ created paperless database"
else
    echo "✓ paperless database exists"
fi

# Make consume/export dirs
mkdir -p /home_ai/storage/paperless/consume /home_ai/storage/paperless/export
echo "✓ storage dirs ready"

# Export env vars for compose
cat > /tmp/u62-paperless.env <<EOF
PAPERLESS_DB_PASSWORD=$PL_DB_PW
PAPERLESS_ADMIN_PASSWORD=$PL_ADMIN_PW
PAPERLESS_SECRET_KEY=$PL_SECRET
EOF

echo
echo "Bootstrap done. To bring Paperless up:"
echo "  set -a; . /tmp/u62-paperless.env; set +a"
echo "  docker compose up -d paperless"
echo
echo "Then visit:  http://100.104.82.53:8011  (login: jo / <admin_password>)"
echo "Admin password is in vault: docker exec -e VAULT_TOKEN=\$VT homeai-vault vault kv get -field=admin_password secret/paperless"
