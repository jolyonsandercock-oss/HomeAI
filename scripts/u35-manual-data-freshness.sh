#!/bin/bash
# u35-manual-data-freshness.sh — daily Telegram report of manual-input data
# staleness. Covers: Dojo CSV drops, bank transactions (per account),
# credit card PDF statements (per card), mortgage statements (per account).
#
# Reads telegram creds from /home_ai/security/.vault-watchdog-creds
# (vault-independent), so this still works during a vault outage.
#
# Run as a user that can `docker exec homeai-postgres` and read the creds.
# Currently that means root (creds file is root:root 0600).

set -uo pipefail

CREDS=/home_ai/security/.vault-watchdog-creds
[[ -r "$CREDS" ]] || { echo "✗ $CREDS unreadable (need root)"; exit 1; }
# shellcheck source=/dev/null
. "$CREDS"
[[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] \
  || { echo "✗ creds file missing TG_BOT_TOKEN or TG_CHAT_ID"; exit 1; }

# Query — returns one row per stale/warn source.
# Filters via bank_accounts.exclude_from_freshness (V204) instead of
# name substring — set the flag in postgres to mute an account.
read -r -d '' SQL <<'EOSQL' || true
WITH src AS (
  SELECT 'Dojo CSV drops' AS source,
         '(all accounts)' AS label,
         MAX(transaction_date) AS last_dated,
         (CURRENT_DATE - MAX(transaction_date)) AS days_stale,
         1::int AS warn_d, 2::int AS stale_d
    FROM dojo_transactions
  UNION ALL
  SELECT 'Bank — ' || ba.bank_name,
         ba.account_name,
         MAX(bt.transaction_date),
         (CURRENT_DATE - MAX(bt.transaction_date)),
         CASE ba.account_type WHEN 'current' THEN 7 WHEN 'credit_card' THEN 40 ELSE 30 END,
         CASE ba.account_type WHEN 'current' THEN 30 WHEN 'credit_card' THEN 70 ELSE 90 END
    FROM bank_accounts ba
    LEFT JOIN bank_transactions bt ON bt.bank_account_id = ba.id
   WHERE ba.exclude_from_freshness = false
   GROUP BY ba.id, ba.bank_name, ba.account_name, ba.account_type
  UNION ALL
  SELECT 'Card statement — ' || ba.bank_name,
         ba.account_name,
         MAX(cs.period_end),
         (CURRENT_DATE - MAX(cs.period_end)),
         40, 70
    FROM bank_accounts ba
    LEFT JOIN card_statements cs ON cs.bank_account_id = ba.id
   WHERE ba.account_type = 'credit_card'
     AND ba.exclude_from_freshness = false
   GROUP BY ba.id, ba.bank_name, ba.account_name
  UNION ALL
  SELECT 'Mortgage — ' || ma.lender,
         ma.account_ref,
         MAX(msp.period_end),
         (CURRENT_DATE - MAX(msp.period_end)),
         40, 90
    FROM mortgage_accounts ma
    LEFT JOIN mortgage_statement_periods msp ON msp.mortgage_account_id = ma.id
   WHERE ma.closed_date IS NULL
     AND ma.exclude_from_freshness = false
   GROUP BY ma.id, ma.lender, ma.account_ref
)
SELECT source, label,
       COALESCE(last_dated::text, 'never'),
       COALESCE(days_stale::text, ''),
       CASE
         WHEN last_dated IS NULL THEN 'never'
         WHEN days_stale > stale_d THEN 'stale'
         WHEN days_stale > warn_d THEN 'warn'
         ELSE 'ok'
       END AS status
  FROM src
 WHERE last_dated IS NULL OR days_stale > warn_d
 ORDER BY CASE WHEN last_dated IS NULL THEN 99999 ELSE days_stale END DESC;
EOSQL

ROWS=$(docker exec homeai-postgres psql -U postgres -d homeai -tA -F '|' -c "$SQL" 2>&1)
DBRC=$?

if [[ $DBRC -ne 0 ]]; then
  TEXT="⚠ <b>Manual data freshness query failed</b>
<pre>$(printf '%s' "$ROWS" | head -c 400 | sed 's/[<>&]//g')</pre>"
else
  if [[ -z "$ROWS" ]]; then
    TEXT="✓ <b>Manual data — all caught up</b>
Dojo CSVs, bank statements, card statements, and mortgage statements are all within their freshness windows. Nice."
  else
    STALE_N=$(printf '%s\n' "$ROWS" | grep -c '|stale$' || true)
    WARN_N=$(printf '%s\n' "$ROWS" | grep -c '|warn$' || true)
    NEVER_N=$(printf '%s\n' "$ROWS" | grep -c '|never$' || true)

    HEADER="📂 <b>Manual data freshness</b>
$STALE_N stale · $WARN_N warn · $NEVER_N never imported"

    BODY=$(printf '%s\n' "$ROWS" | awk -F'|' '
      {
        icon = ($5 == "stale" ? "🔴" : ($5 == "warn" ? "🟡" : "⚪"))
        age = ($4 == "" ? "—" : $4 "d")
        printf "%s <b>%s</b> · <code>%s</code>\n   last %s · %s\n", icon, $1, $2, $3, age
      }
    ')

    FOOTER="
Drop new files into:
• Dojo CSVs → <code>/home_ai/data/dojo-inbox/</code>
• Bank/Card/Mortgage PDFs → Paperless (tag appropriately)"

    TEXT="$HEADER

$BODY$FOOTER"
  fi
fi

RESP=$(curl -sS --max-time 15 \
  -d "chat_id=$TG_CHAT_ID" \
  -d "parse_mode=HTML" \
  -d "disable_web_page_preview=true" \
  --data-urlencode "text=$TEXT" \
  "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" 2>&1)

if printf '%s' "$RESP" | grep -q '"ok":true'; then
  echo "$(date -Iseconds) sent ($(printf '%s' "$ROWS" | wc -l) rows)"
else
  echo "$(date -Iseconds) ✗ telegram send failed: $RESP" >&2
  exit 1
fi
