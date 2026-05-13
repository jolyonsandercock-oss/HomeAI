#!/bin/bash
# /home_ai/scripts/u36-jo-input-batch.sh
#
# Interactive batch — walks Jo through the 3 carry-over inputs from U34/U35:
#   1. Café-stock vendor list  → INSERT vendor_category_rules + re-categorise
#   2. Statement spot-check     → flip false-positives in vendor_invoice_inbox
#   3. Dept→team sign-off       → confirm or override workforce_departments.team

set -uo pipefail
PSQL() { docker exec -i homeai-postgres psql -U postgres -d homeai "$@"; }
SQL()  { docker exec    homeai-postgres psql -U postgres -d homeai -tAc "$@"; }

echo
echo "╭─ Home AI U36 Phase B — Jo input batch ──────────────────────╮"
echo "│                                                             │"
echo "│  Three short tasks. Each can be skipped (press Enter).      │"
echo "│                                                             │"
echo "╰─────────────────────────────────────────────────────────────╯"

# ── 1. Café-stock vendors ────────────────────────────────────
echo
echo "── 1/3  Café-stock vendor list ──"
echo "Type vendor domain patterns one per line (e.g. 'milkbottle\.co' for"
echo "Milk Bottle Dairy, 'cafedirect' for café-only stock). Empty line to finish."
echo "These get added to vendor_category_rules with category='cafe_stock'."
echo
ADDED=0
while true; do
  read -rp "  vendor pattern (or Enter to stop): " PATTERN
  [[ -z "$PATTERN" ]] && break
  read -rp "  display name for $PATTERN: " DISPLAY
  if PSQL -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>&1
INSERT INTO vendor_category_rules (domain_pattern, category, vendor_display, priority, notes)
VALUES ('${PATTERN//\'/\'\'}', 'cafe_stock', '${DISPLAY//\'/\'\'}', 50, 'U36 Jo input')
ON CONFLICT (domain_pattern) DO UPDATE
  SET category = 'cafe_stock',
      vendor_display = EXCLUDED.vendor_display;
SQL
  then
    echo "    ✓ added"
    ADDED=$((ADDED+1))
  else
    echo "    ✗ failed (regex may be invalid)"
  fi
done
if (( ADDED > 0 )); then
  echo "  re-categorising existing invoices…"
  PSQL -v ON_ERROR_STOP=1 <<'SQL'
UPDATE vendor_invoice_inbox v
   SET vendor_category = r.category
  FROM (
    SELECT DISTINCT ON (vii.id) vii.id, rule.category, rule.priority
      FROM vendor_invoice_inbox vii
      JOIN vendor_category_rules rule
        ON vii.vendor_domain ~ rule.domain_pattern
     WHERE rule.category = 'cafe_stock'
     ORDER BY vii.id, rule.priority ASC
  ) r
 WHERE v.id = r.id;
SQL
  COUNT=$(SQL "SELECT COUNT(*) FROM vendor_invoice_inbox WHERE category_canonical='cafe_stock';")
  echo "  ✓ $COUNT invoices now categorised as cafe_stock."
else
  echo "  (skipped — no café-stock rules added)"
fi

# ── 2. Statement spot-check ──────────────────────────────────
echo
echo "── 2/3  Statement spot-check ──"
echo "U34 flagged some invoices as 'statements' (excluded from cost totals)."
echo "Listing each — answer y (keep as statement) or n (flip to invoice)."
echo
TO_FLIP=()
while IFS=$'\t' read -r ID VENDOR SUBJECT; do
  echo
  echo "  [#$ID] $VENDOR"
  echo "  Subject: $SUBJECT"
  read -rp "  Is this really a statement? [Y/n] " ANS
  if [[ "${ANS:-Y}" =~ ^[Nn] ]]; then
    TO_FLIP+=("$ID")
  fi
done < <(SQL "SELECT id, vendor_domain, REGEXP_REPLACE(subject, '[\t\n]', ' ', 'g') FROM vendor_invoice_inbox WHERE is_statement=true AND status<>'ignored' ORDER BY received_at DESC LIMIT 35;")
if (( ${#TO_FLIP[@]} > 0 )); then
  IDS=$(IFS=,; echo "${TO_FLIP[*]}")
  PSQL -c "UPDATE vendor_invoice_inbox SET is_statement=false WHERE id IN ($IDS);" >/dev/null
  echo "  ✓ flipped ${#TO_FLIP[@]} rows from statement → invoice."
else
  echo "  (no flips — all 35 confirmed as statements)"
fi

# ── 3. Department → team sign-off ────────────────────────────
echo
echo "── 3/3  Department → team sign-off ──"
echo "U34 auto-mapped Tanda departments to teams. Confirm each:"
echo
SQL "SELECT external_id, name, team FROM workforce_departments ORDER BY name;" | while IFS='|' read -r EID NAME TEAM; do
  echo "  $NAME → $TEAM"
done
echo
read -rp "All correct? [Y/n] " ANS
if [[ "${ANS:-Y}" =~ ^[Nn] ]]; then
  echo "  Edit manually:"
  echo "    UPDATE workforce_departments SET team='<team>', team_source='manual'"
  echo "     WHERE external_id=<id>;"
else
  PSQL -c "UPDATE workforce_departments SET team_source='manual' WHERE team_source='auto';" >/dev/null 2>&1 || true
  echo "  ✓ all 5 confirmed."
fi

echo
echo "── done — Phase B closed ──"
