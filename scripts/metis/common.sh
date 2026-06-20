# scripts/metis/common.sh — shared DB access for Metis scripts. Source, don't exec.
# Connects to homeai-postgres as superuser using the Vault-stored password.
_metis_pw() {
  local vt
  vt=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' \
       | grep '^VAULT_TOKEN=' | cut -d= -f2-)
  docker exec -e VAULT_TOKEN="$vt" homeai-vault vault kv get -field=password secret/postgres 2>/dev/null
}
METIS_GUC="SET app.current_entity='all'; SET app.current_realm='owner';"
metis_psql() {                      # passes args through to psql
  local pw; pw=$(_metis_pw)
  docker exec -i -e PGPASSWORD="$pw" homeai-postgres \
    psql -U postgres -d homeai -v ON_ERROR_STOP=1 "$@"
}
metis_psql_value() {                # one scalar
  local pw; pw=$(_metis_pw)
  docker exec -i -e PGPASSWORD="$pw" homeai-postgres \
    psql -U postgres -d homeai -tAc "$1"
}
