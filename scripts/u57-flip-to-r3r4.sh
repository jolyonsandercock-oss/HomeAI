#!/usr/bin/env bash
#
# u57-flip-to-r3r4.sh — In-person walkthrough for Realm R3 (Auth) + R4
# (App route split). Run as user `joly` from anywhere; will sudo for the
# cert + root-owned config writes.
#
# What this does, in order, with rollback on any failure:
#   1. Mints `sudo tailscale cert jolybox.tailc27dff.ts.net`
#   2. Installs cert files to /home_ai/config/caddy/tls/
#   3. Promotes staged Caddyfile (Caddyfile.u57 → Caddyfile, with .bak)
#   4. Promotes staged Authelia config + users_database (sudo-cp from /tmp)
#   5. Recreates homeai-caddy + homeai-authelia (compose has a new volume
#      mount in this branch so a plain restart is insufficient)
#   6. Smoke: hits https://jolybox.tailc27dff.ts.net/healthz → expect 200
#   7. Smoke: hits https://jolybox.tailc27dff.ts.net/dashboard/ → expect 302
#   8. Flips REALM_ENFORCE=1 in docker-compose.yml
#   9. Rebuilds + restarts homeai-build-dashboard
#  10. Final smoke with cookie jar via the Authelia portal
#
# Idempotent: re-running after a partial success picks up where it left off.
#
# Exit codes:
#   0  green
#   1  failure (rollback attempted)
#   2  pre-flight error

set -euo pipefail

FQDN="jolybox.tailc27dff.ts.net"
HOMEAI="/home_ai"
TLS_DIR="${HOMEAI}/config/caddy/tls"
CADDYFILE="${HOMEAI}/config/caddy/Caddyfile"
CADDYFILE_NEW="${HOMEAI}/config/caddy/Caddyfile.u57"
AUTHELIA_DIR="${HOMEAI}/security/authelia-v2"
AUTHELIA_NEW="/tmp/authelia.u57.yml"
USERS_NEW="/tmp/users_database.u57.yml"
COMPOSE="${HOMEAI}/docker-compose.yml"
STAMP=$(date +%Y-%m-%d-%H%M)

LOG_PFX="[u57-flip]"
say() { echo "${LOG_PFX} $*"; }
die() { echo "${LOG_PFX} ERROR: $*" >&2; exit 1; }

rollback() {
    say "rollback — restoring pre-flip state"
    [[ -f "${CADDYFILE}.bak-${STAMP}" ]] && cp "${CADDYFILE}.bak-${STAMP}" "${CADDYFILE}" && say "caddyfile restored"
    [[ -f "${COMPOSE}.bak-${STAMP}" ]] && cp "${COMPOSE}.bak-${STAMP}" "${COMPOSE}" && say "compose restored"
    sudo cp -f "${AUTHELIA_DIR}/configuration.yml.bak-${STAMP}" "${AUTHELIA_DIR}/configuration.yml" 2>/dev/null || true
    sudo cp -f "${AUTHELIA_DIR}/users_database.yml.bak-${STAMP}" "${AUTHELIA_DIR}/users_database.yml" 2>/dev/null || true
    (cd "${HOMEAI}" && docker compose restart caddy authelia build-dashboard 2>&1 | tail -3) || true
    say "rollback done — verify with: curl -sv http://100.104.82.53/dashboard/api/healthz"
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi' EXIT

# -----------------------------------------------------------------------------
# Step 0 — Pre-flight
# -----------------------------------------------------------------------------

say "step 0: pre-flight"

[[ -f "${CADDYFILE_NEW}" ]] || die "staged Caddyfile not found at ${CADDYFILE_NEW}. Did U57 prep run?"
[[ -f "${AUTHELIA_NEW}" ]] || die "staged Authelia config not found at ${AUTHELIA_NEW}"
[[ -f "${USERS_NEW}" ]]    || die "staged users_database not found at ${USERS_NEW}"
docker ps --filter name=homeai-caddy    --format '{{.Names}}' | grep -q homeai-caddy    || die "homeai-caddy not running"
docker ps --filter name=homeai-authelia --format '{{.Names}}' | grep -q homeai-authelia || die "homeai-authelia not running"
command -v tailscale >/dev/null || die "tailscale CLI not found"

# -----------------------------------------------------------------------------
# Step 1 — Mint tailscale cert (idempotent — skip if files already in place)
# -----------------------------------------------------------------------------

if [[ -f "${TLS_DIR}/${FQDN}.crt" && -f "${TLS_DIR}/${FQDN}.key" ]]; then
    say "step 1: cert already at ${TLS_DIR}/ — skip mint"
else
    say "step 1: minting tailscale cert for ${FQDN} (will prompt for sudo)"
    pushd "${TLS_DIR}" >/dev/null
    sudo tailscale cert "${FQDN}" || die "tailscale cert failed"
    sudo chmod 644 "${FQDN}.crt"
    sudo chmod 644 "${FQDN}.key"   # readable inside container (caddy runs as 0:0 typically)
    sudo chown "$(id -u):$(id -g)" "${FQDN}.crt" "${FQDN}.key"
    popd >/dev/null
    ls -la "${TLS_DIR}/" | tail -3
fi

# -----------------------------------------------------------------------------
# Step 2a — Bring the tls bind mount into the live Caddy container.
#
# The compose change adding `./config/caddy/tls:/etc/caddy/tls:ro` was made
# in the prep commit, but until the container is recreated the mount isn't
# visible — and `caddy validate` against the new Caddyfile fails the
# "loading certificates" check.
#
# Recreate Caddy with the (still-old) Caddyfile so the mount lands cleanly.
# IP-based routes briefly cycle (~1s).
# -----------------------------------------------------------------------------

if docker exec homeai-caddy ls /etc/caddy/tls/ >/dev/null 2>&1; then
    say "step 2a: tls mount already visible inside homeai-caddy — skip recreate"
else
    say "step 2a: recreating homeai-caddy to pick up the tls volume mount"
    cd "${HOMEAI}"
    docker compose up -d --no-deps caddy 2>&1 | tail -2
    for i in 1 2 3 4 5; do
        docker exec homeai-caddy ls /etc/caddy/tls/ >/dev/null 2>&1 && break
        sleep 1
    done
    docker exec homeai-caddy ls /etc/caddy/tls/ >/dev/null 2>&1 \
        || die "tls mount still not visible after recreate"
    say "        mount in place: $(docker exec homeai-caddy ls /etc/caddy/tls/ | tr '\n' ' ')"
fi

# -----------------------------------------------------------------------------
# Step 2b — Validate the staged Caddyfile (cert files now visible)
# -----------------------------------------------------------------------------

say "step 2b: validate Caddyfile.u57"
docker cp "${CADDYFILE_NEW}" homeai-caddy:/etc/caddy/Caddyfile.u57 >/dev/null
docker exec homeai-caddy caddy validate --config /etc/caddy/Caddyfile.u57 2>&1 | tail -3 \
  | grep -q "Valid configuration" || die "Caddyfile.u57 validation failed"
say "        Caddyfile.u57 valid"

# -----------------------------------------------------------------------------
# Step 3 — Promote configs (with backups)
# -----------------------------------------------------------------------------

say "step 3: backup + promote configs (stamp=${STAMP})"
cp "${CADDYFILE}" "${CADDYFILE}.bak-${STAMP}"
cp "${COMPOSE}"   "${COMPOSE}.bak-${STAMP}"
sudo cp "${AUTHELIA_DIR}/configuration.yml"  "${AUTHELIA_DIR}/configuration.yml.bak-${STAMP}"
sudo cp "${AUTHELIA_DIR}/users_database.yml" "${AUTHELIA_DIR}/users_database.yml.bak-${STAMP}"

cp "${CADDYFILE_NEW}" "${CADDYFILE}"
sudo cp "${AUTHELIA_NEW}" "${AUTHELIA_DIR}/configuration.yml"
sudo cp "${USERS_NEW}"    "${AUTHELIA_DIR}/users_database.yml"
sudo chown root:root "${AUTHELIA_DIR}/configuration.yml" "${AUTHELIA_DIR}/users_database.yml"
sudo chmod 600 "${AUTHELIA_DIR}/configuration.yml" "${AUTHELIA_DIR}/users_database.yml"
say "        live configs promoted"

# -----------------------------------------------------------------------------
# Step 4 — Recreate Caddy + Authelia (compose has new tls bind mount)
# -----------------------------------------------------------------------------

say "step 4: force-recreate caddy + authelia so they pick up new configs"
cd "${HOMEAI}"
# Force-recreate: a bind-mount file change alone doesn't reload Caddy (or
# Authelia) — compose sees the container spec is unchanged and leaves it
# running with stale config in memory.
docker compose up -d --no-deps --force-recreate caddy authelia 2>&1 | tail -3

# Give them a moment to come up + bind 443
for i in 1 2 3 4 5 6 7 8 9 10; do
    docker exec homeai-caddy wget -qO- http://localhost/healthz 2>/dev/null | grep -q "ok" && break
    sleep 1
done

# -----------------------------------------------------------------------------
# Step 5 — Smoke: FQDN + TLS + Authelia portal reachable
# -----------------------------------------------------------------------------

say "step 5: smoke (FQDN reachable via HTTPS)"
healthz=$(curl -sk -o /dev/null -w "%{http_code}" "https://${FQDN}/healthz" || true)
[[ "${healthz}" == "200" ]] || die "FQDN /healthz returned ${healthz} (expected 200)"

dash=$(curl -sk -o /dev/null -w "%{http_code}" "https://${FQDN}/dashboard/api/healthz" || true)
# Without an Authelia cookie this should redirect (302) to /auth/
[[ "${dash}" == "302" || "${dash}" == "401" ]] || die "/dashboard returned ${dash} (expected 302 or 401)"

auth=$(curl -sk -o /dev/null -w "%{http_code}" "https://${FQDN}/auth/" || true)
[[ "${auth}" == "200" || "${auth}" == "302" ]] || die "/auth/ returned ${auth} (expected 200/302)"

say "        /healthz=${healthz} /dashboard=${dash} (gated) /auth/=${auth}"

# -----------------------------------------------------------------------------
# Step 6 — Flip REALM_ENFORCE=1 + rebuild build-dashboard
# -----------------------------------------------------------------------------

say "step 6: flip REALM_ENFORCE=1 on build-dashboard"
if grep -q 'REALM_ENFORCE: "0"' "${COMPOSE}"; then
    sed -i 's/REALM_ENFORCE: "0"/REALM_ENFORCE: "1"/' "${COMPOSE}"
    say "        compose flipped 0 → 1"
else
    say "        REALM_ENFORCE already 1 (or not present) — skip"
fi

# Rebuild image (main.py middleware reads Remote-Groups now per U57 prep)
say "        rebuilding homeai-build-dashboard image"
docker compose build build-dashboard 2>&1 | tail -1

# Harvest POSTGRES_PASSWORD per [[feedback_dashboard_image_rebuild]]
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="${VT}" homeai-vault vault kv get -field=password secret/postgres)
POSTGRES_PASSWORD="${PG_PW}" docker compose up -d --no-deps build-dashboard 2>&1 | tail -2
unset VT PG_PW POSTGRES_PASSWORD

# Wait for ready
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -f -o /dev/null http://100.104.82.53:8090/api/healthz; then
        say "        build-dashboard up after ${i}s"
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------------------
# Step 7 — Final smoke: enforcement path
# -----------------------------------------------------------------------------

say "step 7: final smoke (REALM_ENFORCE=1 enforcement)"

# Direct (non-Caddy) hit without any realm header should now 401.
direct=$(curl -s -o /dev/null -w "%{http_code}" http://100.104.82.53:8090/api/snapshot)
[[ "${direct}" == "401" ]] || die "direct /api/snapshot returned ${direct} (expected 401 — REALM_ENFORCE didn't take?)"

# With X-Realm work it should 200.
work=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Realm: work" http://100.104.82.53:8090/api/snapshot)
[[ "${work}" == "200" ]] || die "X-Realm=work returned ${work} (expected 200)"

# Through the FQDN without a cookie should redirect to /auth/.
fqdn_dash=$(curl -sk -o /dev/null -w "%{http_code}" "https://${FQDN}/dashboard/api/healthz")
[[ "${fqdn_dash}" == "302" || "${fqdn_dash}" == "401" ]] || die "FQDN /dashboard returned ${fqdn_dash} (expected 302/401 unauth)"

say "        direct no-header=${direct} (401) | X-Realm=work=${work} (200) | FQDN unauth=${fqdn_dash} (302/401)"

# -----------------------------------------------------------------------------
# Step 8 — Telegram pulse + done
# -----------------------------------------------------------------------------

bash /home_ai/.claude/scripts/notify-telegram.sh \
    "<b>U57 R3+R4 flip complete</b>%0A• tailscale cert minted%0A• Caddy FQDN listener live with forward_auth%0A• REALM_ENFORCE=1 on build-dashboard%0A• IP-based routes preserved as rollback path%0A• Test login: https://${FQDN}/dashboard/" \
    "u57-flip" >/dev/null || true

# Clear the trap — we made it.
trap - EXIT

say "DONE. Verify in your browser:"
say "  https://${FQDN}/dashboard/  →  should redirect to /auth/, login as 'jo'"
say "  https://${FQDN}/auth/        →  Authelia portal direct"
say ""
say "Rollback (if needed):"
say "  cp ${CADDYFILE}.bak-${STAMP} ${CADDYFILE}"
say "  cp ${COMPOSE}.bak-${STAMP} ${COMPOSE}"
say "  sudo cp ${AUTHELIA_DIR}/configuration.yml.bak-${STAMP} ${AUTHELIA_DIR}/configuration.yml"
say "  sudo cp ${AUTHELIA_DIR}/users_database.yml.bak-${STAMP} ${AUTHELIA_DIR}/users_database.yml"
say "  cd ${HOMEAI} && docker compose restart caddy authelia build-dashboard"
