#!/usr/bin/env bash
#
# u52-realm-middleware-smoke.sh — verify the build-dashboard realm middleware.
#
# Default mode: check the LIVE container (REALM_ENFORCE=0 dormant) — proves
# the middleware is loaded, ignores X-Realm header, and serves traffic
# regression-free.
#
# --enforce mode: spins up a temporary parallel container on port 8091 with
# REALM_ENFORCE=1, asserts the gate fires, then tears it down. Use this
# after R3 (Authelia) lands or as a one-off integration check.
#
# Exit codes:
#   0  green
#   1  smoke assertion failed
#   2  setup error

set -euo pipefail

DASH_BASE="${DASH_BASE:-http://100.104.82.53:8090}"
TMP_PORT=8091
TMP_NAME=homeai-build-dashboard-smoke

curl_code() {
    # $1 path, [$2 header value]
    local path="$1"
    local hdr="${2:-}"
    if [[ -n "$hdr" ]]; then
        curl -s -o /dev/null -w "%{http_code}" -H "X-Realm: ${hdr}" "${DASH_BASE}${path}"
    else
        curl -s -o /dev/null -w "%{http_code}" "${DASH_BASE}${path}"
    fi
}

assert_code() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  OK   %-50s  %s\n" "$label" "$actual"
    else
        printf "  FAIL %-50s  expected=%s observed=%s\n" "$label" "$expected" "$actual"
        return 1
    fi
}

mode="${1:-default}"

case "$mode" in
    default)
        echo "Live container (REALM_ENFORCE=0, dormant)..."
        fails=0
        assert_code 200 "$(curl_code /api/healthz)"               "healthz no header"        || fails=$((fails+1))
        assert_code 200 "$(curl_code /api/healthz work)"          "healthz X-Realm=work"     || fails=$((fails+1))
        assert_code 200 "$(curl_code /api/snapshot)"              "snapshot no header"       || fails=$((fails+1))
        assert_code 200 "$(curl_code /api/snapshot work)"         "snapshot X-Realm=work"    || fails=$((fails+1))
        assert_code 200 "$(curl_code /api/snapshot family)"       "snapshot X-Realm=family"  || fails=$((fails+1))
        assert_code 200 "$(curl_code /api/snapshot 'garbage val')" "snapshot X-Realm=garbage" || fails=$((fails+1))
        if [[ $fails -ne 0 ]]; then
            echo "FAIL: ${fails} dormant-mode assertion(s) failed." >&2
            exit 1
        fi
        echo "PASS: dormant middleware regression-free."
        echo
        echo "To exercise REALM_ENFORCE=1 path: $0 --enforce"
        exit 0
        ;;

    --enforce)
        # Spin up a parallel container on the same internal network as the
        # live one. ai-internal blocks port publishing (internal: true), so
        # we run curls from inside the network rather than via the host.
        echo "Spawning parallel container ${TMP_NAME} on home_ai_ai-internal..."
        VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' \
              | grep '^VAULT_TOKEN=' | cut -d= -f2-)
        if [[ -z "$VT" ]]; then
            echo "ERROR: could not harvest VAULT_TOKEN from homeai-google-fetch." >&2
            exit 2
        fi
        PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
        cleanup() { docker rm -f "$TMP_NAME" >/dev/null 2>&1 || true; }
        trap cleanup EXIT

        docker run -d --rm --name "$TMP_NAME" \
            --network home_ai_ai-internal \
            -e "PG_DSN=postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai" \
            -e "REALM_ENFORCE=1" \
            homeai-build-dashboard:2.0 >/dev/null
        unset PG_PW VT
        sleep 5

        # In-network HTTP probe: exec into homeai-vault (alpine, has wget) and
        # hit the smoke container by its name. Pull the response code from the
        # first "HTTP/1.1 NNN ..." line that wget -S prints to stderr.
        net_curl_code() {
            local path="$1"
            local realm="${2:-}"
            local hdr_args=""
            [[ -n "$realm" ]] && hdr_args="--header=X-Realm:${realm}"
            docker exec homeai-vault sh -c \
                "wget -q -S -O /dev/null ${hdr_args} http://${TMP_NAME}:8090${path} 2>&1 || true" \
              | sed -nE 's@.*HTTP/[0-9.]+ ([0-9]{3}).*@\1@p' | head -n1
        }

        echo "Enforced container live. Testing..."
        fails=0
        assert_code 200 "$(net_curl_code /api/healthz '')"        "healthz exempt (no header)"     || fails=$((fails+1))
        assert_code 401 "$(net_curl_code /api/snapshot '')"       "snapshot rejects no header"     || fails=$((fails+1))
        assert_code 401 "$(net_curl_code /api/snapshot bogus)"    "snapshot rejects invalid header"|| fails=$((fails+1))
        assert_code 200 "$(net_curl_code /api/snapshot work)"     "snapshot accepts X-Realm=work"  || fails=$((fails+1))
        assert_code 200 "$(net_curl_code /api/snapshot family)"   "snapshot accepts X-Realm=family"|| fails=$((fails+1))
        assert_code 200 "$(net_curl_code /api/snapshot owner)"    "snapshot accepts X-Realm=owner" || fails=$((fails+1))

        if [[ $fails -ne 0 ]]; then
            echo "FAIL: ${fails} enforced-mode assertion(s) failed." >&2
            exit 1
        fi
        echo "PASS: enforced middleware gate fires correctly."
        exit 0
        ;;

    *)
        echo "Usage: $0 [--enforce]" >&2
        exit 2
        ;;
esac
