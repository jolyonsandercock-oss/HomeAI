#!/bin/bash
# /home_ai/.claude/scripts/u26-children.sh
#
# Replace the 3 PLACEHOLDER children rows with real data. Interactive — asks
# for each child's name + DOB + school name + school email domain.
#
# Closes the "Placeholder children in DB" debt item — unblocks P8 Nanny
# classifier accuracy (it cross-checks school email domains against this table).
#
# Run as your normal user. No root needed.
#
# Idempotent re-run pattern: if a child has a real name already, this script
# offers to skip or update it.

set -uo pipefail
PSQL() { docker exec -i homeai-postgres psql -U postgres -d homeai "$@"; }
sql()  { docker exec    homeai-postgres psql -U postgres -d homeai -tAc "$@" 2>/dev/null; }

YEL='\033[0;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}── U26: Children real data ──${NC}"
echo "I'll walk through each child currently in the DB. Press Enter to skip a"
echo "field (leaves existing value or blank)."
echo

ids=$(sql "SELECT id FROM children ORDER BY id;")
[[ -z "$ids" ]] && { echo "no rows in children table"; exit 0; }

for id in $ids; do
  cur=$(sql "SELECT name || '|' || COALESCE(date_of_birth::text, '') || '|' || COALESCE(school_name, '') || '|' || COALESCE(school_email_domain, '') FROM children WHERE id=$id;")
  IFS='|' read -r cur_name cur_dob cur_school cur_dom <<<"$cur"

  echo -e "${YEL}Child id=$id${NC}  current: name='$cur_name' dob='$cur_dob' school='$cur_school' domain='$cur_dom'"

  read -rp "  Name (Enter to keep): " new_name; new_name="${new_name:-$cur_name}"
  read -rp "  DOB YYYY-MM-DD (Enter to keep): " new_dob; new_dob="${new_dob:-$cur_dob}"
  read -rp "  School name (Enter to keep): " new_school; new_school="${new_school:-$cur_school}"
  read -rp "  School email domain (e.g. stmaryskindergarten.example.com) (Enter to keep): " new_dom; new_dom="${new_dom:-$cur_dom}"

  if [[ "$new_name" == PLACEHOLDER* ]]; then
    echo "  (still PLACEHOLDER — leaving for next run)"
    echo
    continue
  fi

  # Empty-string columns should land as NULL
  dob_sql=$([[ -z "$new_dob" ]] && echo "NULL" || echo "'$new_dob'")
  school_sql=$([[ -z "$new_school" ]] && echo "NULL" || echo "\$pl\$$new_school\$pl\$")
  dom_sql=$([[ -z "$new_dom" ]] && echo "NULL" || echo "\$pl\$$new_dom\$pl\$")

  PSQL >/dev/null <<EOF
SET row_security = off;
UPDATE children
   SET name = \$pl\$$new_name\$pl\$,
       date_of_birth = $dob_sql,
       school_name = $school_sql,
       school_email_domain = $dom_sql
 WHERE id = $id;
EOF
  echo -e "  ${GREEN}✓${NC} updated id=$id"
  echo
done

echo
echo "Final state:"
docker exec homeai-postgres psql -U postgres -d homeai -c "SELECT id, name, date_of_birth, school_name, school_email_domain FROM children ORDER BY id;"

# Update debt.yaml: remove the placeholder-children entry
DEBT=/home_ai/services/build-dashboard/data/debt.yaml
if grep -q 'Placeholder children in DB' "$DEBT"; then
  remaining=$(sql "SELECT COUNT(*) FROM children WHERE name LIKE 'PLACEHOLDER%';")
  if [[ "$remaining" = "0" ]]; then
    python3 -c "
import re
src = open('$DEBT').read()
src = re.sub(r'\n\s*- severity: low\n\s*title: Placeholder children in DB.*?(?=\n  - |\Z)', '', src, count=1, flags=re.DOTALL)
open('$DEBT', 'w').write(src)
"
    echo
    echo -e "${GREEN}✓${NC} all placeholders gone — removed debt entry"
  else
    echo
    echo "($remaining placeholder(s) remaining — debt entry kept)"
  fi
fi
