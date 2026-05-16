#!/bin/bash
# U84 Phase 8 — Route smoke test for the new IA.
# Hits every U84 route from inside the dashboard container, with both
# X-Realm: work and X-Realm: all, and asserts a 200 response.
# Also smokes the new slug endpoints and confirms expected non-empty rows.

set -uo pipefail

PASS=0
FAIL=0
FAILURES=()

check() {
  local label="$1"
  local realm="$2"
  local path="$3"
  local expect="${4:-200}"
  out=$(docker exec homeai-build-dashboard curl -s -o /dev/null -w "%{http_code}" -H "X-Realm: $realm" "http://localhost:8090$path")
  if [ "$out" = "$expect" ]; then
    PASS=$((PASS + 1))
    printf "  \e[32mOK\e[0m  [%s] %-30s → HTTP %s\n" "$realm" "$path" "$out"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[$realm] $path → got $out, want $expect")
    printf "  \e[31mFAIL\e[0m [%s] %-30s → HTTP %s (want %s)\n" "$realm" "$path" "$out" "$expect"
  fi
}

slug_check() {
  local label="$1"
  local realm="$2"
  local slug="$3"
  body=$(docker exec homeai-build-dashboard curl -s -H "X-Realm: $realm" "http://localhost:8090/api/finance/slug/$slug")
  if echo "$body" | grep -q '"n_rows"'; then
    PASS=$((PASS + 1))
    printf "  \e[32mOK\e[0m  [%s] slug/%-25s\n" "$realm" "$slug"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[$realm] slug/$slug → no n_rows in response")
    printf "  \e[31mFAIL\e[0m [%s] slug/%-25s body=%s\n" "$realm" "$slug" "${body:0:80}"
  fi
}

echo "── Header / realm toggle assets ──────────────────────────"
check "vendor" "all" "/static/vendor/tailwind-3.4.min.js"
check "vendor" "all" "/static/vendor/alpine-3.14.min.js"
check "vendor" "all" "/static/vendor/tabulator-6.2.5.min.js"
check "vendor" "all" "/static/vendor/d3-7.9.min.js"
check "component" "all" "/static/_components/realm-toggle.js"
check "component" "all" "/static/_components/header.html"
check "component" "all" "/static/_components/date-window.js"

echo
echo "── Work tabs ────────────────────────────────────────────"
for p in today actions docs staff email finance more; do
  check "work" "work" "/work/$p"
  check "work" "all"  "/work/$p"
done

echo
echo "── Private tabs ─────────────────────────────────────────"
for p in today family email docs actions more; do
  check "priv" "all" "/private/$p"
done

echo
echo "── Build hub ────────────────────────────────────────────"
for p in pipelines models forensics; do
  check "build" "all" "/build/$p"
done

echo
echo "── /all sitemap + search ────────────────────────────────"
check "all" "all" "/all"
check "all" "all" "/api/all/sitemap"
check "all" "all" "/api/all/search?q=mortgage"

echo
echo "── Root redirect ────────────────────────────────────────"
check "root"  "work" "/" "302"
check "root"  "all"  "/" "302"
check "index" "all"  "/index"

echo
echo "── Slugs ────────────────────────────────────────────────"
slug_check "kpi"  "all" "today_kpis_work"
slug_check "kpi"  "all" "today_kpis_private"
slug_check "act"  "all" "action_queue"
slug_check "docs" "all" "work_docs_kpis"
slug_check "stf"  "all" "work_staff_kpis"
slug_check "eml"  "all" "work_email_kpis"
slug_check "pri"  "all" "private_family_kpis"
slug_check "pri"  "all" "private_docs_kpis"
slug_check "bld"  "all" "build_pipeline_status"
slug_check "bld"  "all" "build_model_spend_30d"
slug_check "bld"  "all" "build_forensic_summary"

echo
echo "── Realm-mapping sanity ─────────────────────────────────"
# 'all' maps to DB 'owner' — query should return rows
body=$(docker exec homeai-build-dashboard curl -s -H "X-Realm: all" http://localhost:8090/api/finance/slug/action_queue)
rows=$(echo "$body" | python3 -c "import sys, json; d = json.load(sys.stdin); print(d.get('n_rows', 0))" 2>/dev/null)
if [ "$rows" -gt 0 ] 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  OK   action_queue returns $rows rows when X-Realm=all"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL action_queue returned $rows rows (want > 0)"
fi

# Invalid realm rejected
out=$(docker exec homeai-build-dashboard curl -s -o /dev/null -w "%{http_code}" -H "X-Realm: bogus" http://localhost:8090/api/finance/slug/action_queue)
if [ "$out" = "401" ]; then
  PASS=$((PASS + 1))
  echo "  OK   bogus X-Realm rejected with 401"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL bogus X-Realm got $out, want 401"
fi

echo
echo "═══════════════════════════════════════════════════════════"
echo "Total: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  echo
  echo "Failures:"
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
