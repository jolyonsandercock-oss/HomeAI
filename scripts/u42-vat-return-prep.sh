#!/bin/bash
# /home_ai/scripts/u42-vat-return-prep.sh
#
# Quarterly UK VAT return pre-fill.
# DORMANT — checks system_state.p3_xero='live' before doing any work.
# Per SPEC §7.7.
#
# Cron: 0 6 3 1,4,7,10 *   (3rd of Jan/Apr/Jul/Oct at 06:00)

set -euo pipefail

# ── Dormancy gate ────────────────────────────────────────────
GATE=$(docker exec homeai-postgres psql -U postgres -d homeai -tA -c "
  SELECT value FROM system_state WHERE key='p3_xero';" 2>/dev/null)
if [[ "$GATE" != "live" ]]; then
  echo "$(date -Iseconds) p3_xero=$GATE — VAT prep dormant. Set system_state.p3_xero='live' to activate."
  exit 0
fi

# ── Active path (runs once Xero unblocks) ─────────────────────
echo "$(date -Iseconds) p3_xero=live — running VAT return prep"

docker exec -i homeai-playwright python <<'PYEOF'
import os, asyncio, asyncpg, json
from datetime import date, timedelta
from decimal import Decimal

PG_DSN = os.environ["PG_DSN"]


def previous_quarter_end():
    """Return the most recent past UK VAT quarter end (Mar/Jun/Sep/Dec last day)."""
    today = date.today()
    # Quarter ends: Mar 31, Jun 30, Sep 30, Dec 31
    if today.month <= 3:    return date(today.year - 1, 12, 31)
    if today.month <= 6:    return date(today.year,      3, 31)
    if today.month <= 9:    return date(today.year,      6, 30)
    if today.month <= 12:   return date(today.year,      9, 30)


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='1'")
    q_end = previous_quarter_end()
    q_start = date(q_end.year, q_end.month - 2, 1)  # quarter spans 3 months

    print(f"VAT quarter: {q_start} to {q_end}")

    # NOTE: real implementation pulls Xero figures via OAuth. Until P3 is
    # unblocked, this script is gated above. The below is a structured
    # skeleton showing where the data lookups will go.
    #
    # boxes = await pull_xero_quarter(q_start, q_end)
    # anomalies = compute_anomalies(boxes, prior_quarters)
    # INSERT into vat_returns_log; queue Action Queue card.

    print("(Xero integration not yet built. Activating system_state.p3_xero='live' "
          "without P3 deployed will reach this point and stop.)")
    await conn.close()

asyncio.run(main())
PYEOF
