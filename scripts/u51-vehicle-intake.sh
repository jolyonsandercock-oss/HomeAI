#!/bin/bash
# /home_ai/scripts/u51-vehicle-intake.sh
#
# Guided per-vehicle Q&A. Idempotent on registration — re-running just
# UPDATEs existing rows. Skip a field by pressing Enter.

set -euo pipefail

read_field() {
  local prompt="$1" default="$2" validator="${3:-}"
  while true; do
    local val
    read -r -p "  ${prompt}${default:+ [${default}]}: " val
    val="${val:-$default}"
    if [[ -z "$validator" || -z "$val" ]]; then echo "$val"; return; fi
    if [[ "$val" =~ $validator ]]; then echo "$val"; return; fi
    echo "  ✗ doesn't match expected format. Try again or Enter to skip." >&2
  done
}

echo "── Vehicle intake — Ctrl-C to stop, blank entry to skip a field ──"
echo

while true; do
  echo
  REG=$(read_field "Registration (e.g. AB12 CDE)" "" "^[A-Za-z0-9 ]{1,8}$")
  if [[ -z "$REG" ]]; then echo "(no registration — done)"; break; fi
  REG_UPPER=$(echo "$REG" | tr '[:lower:]' '[:upper:]' | tr -s ' ')

  EXISTING=$(docker exec homeai-postgres psql -U postgres -d homeai -t -A -c "
    SET app.current_entity='all';
    SELECT id || '|' || make_model || '|' || COALESCE(mot_due::text,'')
    FROM vehicles WHERE upper(replace(registration,' ','')) = upper(replace('$REG_UPPER',' ',''))" 2>/dev/null || echo "")
  if [[ -n "$EXISTING" ]]; then
    echo "  ↻ existing row: $EXISTING — values shown as defaults; Enter keeps them."
  fi

  MAKE=$(read_field "Make / model (e.g. Volvo XC60)" "")
  YEAR=$(read_field "Year built (4-digit)" "" "^[0-9]{4}$")
  V5C=$(read_field "V5C reference (top-right of the V5)" "")
  MOT=$(read_field "MOT due (YYYY-MM-DD)" "" "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  INS=$(read_field "Insurance renewal (YYYY-MM-DD)" "" "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  TAX=$(read_field "Road tax due (YYYY-MM-DD)" "" "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  SVC=$(read_field "Next service due date (YYYY-MM-DD)" "" "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  SVCMI=$(read_field "Service due at miles (integer)" "" "^[0-9]+$")
  MI=$(read_field "Current mileage (integer)" "" "^[0-9]+$")
  ENT=$(read_field "Entity id (1=Trading 2=Estates 3=Personal 4=Family)" "3" "^[1-4]$")
  NOTES=$(read_field "Notes (free text)" "")

  # Pass values via env to avoid quoting hell
  docker exec -i \
    -e VREG="$REG_UPPER" -e VMAKE="$MAKE" -e VYEAR="$YEAR" -e VV5C="$V5C" \
    -e VMOT="$MOT" -e VINS="$INS" -e VTAX="$TAX" -e VSVC="$SVC" \
    -e VSVCMI="$SVCMI" -e VMI="$MI" -e VENT="$ENT" -e VNOTES="$NOTES" \
    homeai-playwright python <<'PYEOF'
import os, asyncio, asyncpg
async def main():
    c = await asyncpg.connect(os.environ["PG_DSN"])
    await c.execute("SET app.current_entity='all'")
    def n(v): return None if not v else v
    def ni(v):
        try: return int(v) if v else None
        except: return None
    def nd(v):
        from datetime import date
        try: return date.fromisoformat(v) if v else None
        except: return None
    row = await c.fetchrow("""
      INSERT INTO vehicles (registration, make_model, year_built, v5c_doc_ref,
                            mot_due, insurance_renewal, road_tax_due,
                            service_due_date, service_due_miles, current_miles,
                            entity_id, notes, updated_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12, now())
      ON CONFLICT ((upper(replace(registration,' ','')))) DO UPDATE SET
        make_model        = COALESCE(NULLIF(EXCLUDED.make_model,''),        vehicles.make_model),
        year_built        = COALESCE(EXCLUDED.year_built,                   vehicles.year_built),
        v5c_doc_ref       = COALESCE(NULLIF(EXCLUDED.v5c_doc_ref,''),       vehicles.v5c_doc_ref),
        mot_due           = COALESCE(EXCLUDED.mot_due,                      vehicles.mot_due),
        insurance_renewal = COALESCE(EXCLUDED.insurance_renewal,            vehicles.insurance_renewal),
        road_tax_due      = COALESCE(EXCLUDED.road_tax_due,                 vehicles.road_tax_due),
        service_due_date  = COALESCE(EXCLUDED.service_due_date,             vehicles.service_due_date),
        service_due_miles = COALESCE(EXCLUDED.service_due_miles,            vehicles.service_due_miles),
        current_miles     = COALESCE(EXCLUDED.current_miles,                vehicles.current_miles),
        entity_id         = COALESCE(EXCLUDED.entity_id,                    vehicles.entity_id),
        notes             = COALESCE(NULLIF(EXCLUDED.notes,''),             vehicles.notes),
        updated_at        = now()
      RETURNING id, registration, make_model
    """,
      os.environ["VREG"], os.environ["VMAKE"], ni(os.environ["VYEAR"]),
      n(os.environ["VV5C"]), nd(os.environ["VMOT"]), nd(os.environ["VINS"]),
      nd(os.environ["VTAX"]), nd(os.environ["VSVC"]),
      ni(os.environ["VSVCMI"]), ni(os.environ["VMI"]),
      int(os.environ["VENT"]), os.environ["VNOTES"])
    print(f"  ✓ #{row['id']}  {row['registration']}  {row['make_model']}")
    await c.close()
asyncio.run(main())
PYEOF

  echo
  read -r -p "Add another vehicle? [Y/n]: " more
  if [[ "$more" =~ ^[Nn] ]]; then break; fi
done

echo
echo "── final vehicle list ──"
docker exec homeai-postgres psql -U postgres -d homeai -c "SET app.current_entity='all';
SELECT id, registration, make_model, year_built, mot_due, insurance_renewal, road_tax_due
  FROM vehicles ORDER BY registration"
