#!/usr/bin/env python3
"""Bridge: Playwright TouchOffice scraper -> epos_daily_reports."""
import asyncio, asyncpg, os, sys

PG_DSN = os.environ.get("PG_DSN", "postgresql://postgres@homeai-postgres/homeai")
DRY_RUN = "--dry-run" in sys.argv

# Map touchoffice totaliser_id -> (epos_column, transform_fn)
MAP = {
    2:  ("gross_sales", float),          # GROSS Sales
    1:  ("net_sales", float),            # NET sales
    4:  ("cash_total", float),           # CASH in Drawer
    6:  ("card_total", float),           # CREDIT in Drawer
    19: ("covers", lambda v: float(v)),  # Covers
    18: ("gratuities", float),           # EFT Gratuity
    14: ("refunds", float),              # REFUND mode
    16: ("voids", float),                # Discount Total
    50: ("accommodation_sales", float),  # REMOTE SALES GROSS
}

async def run():
    conn = await asyncpg.connect(PG_DSN)
    # Perf pass 2026-07-03: was the last 60 DISTINCT site-dates, re-read and
    # re-upserted on every 30-min cron run (~120 queries/run) when only
    # today/yesterday ever change. Rolling 3-day window now; for a historical
    # backfill, run manually with the window widened.
    dates = await conn.fetch("""
        SELECT DISTINCT site, report_date FROM touchoffice_fixed_totals
        WHERE site IN ('malthouse','sandwich')
          AND report_date >= current_date - 3
        ORDER BY report_date DESC
    """)
    for r in dates:
        site, dt = r["site"], r["report_date"]
        key = f"to-epos-bridge-{site}-{dt}"
        totals = await conn.fetch("""
            SELECT totaliser_id, value FROM touchoffice_fixed_totals
            WHERE site=$1 AND report_date=$2
        """, site, dt)
        vals = {"gross_sales": 0, "net_sales": 0, "cash_total": 0,
                "card_total": 0, "covers": 0, "gratuities": 0,
                "refunds": 0, "voids": 0, "accommodation_sales": 0}
        for t in totals:
            tid, val = t["totaliser_id"], t["value"]
            if tid in MAP and val is not None:
                col, fn = MAP[tid]
                vals[col] = fn(val) if val else 0
        print(f"{site} {dt}: gross={vals['gross_sales']:.2f} net={vals['net_sales']:.2f} cash={vals['cash_total']:.2f} card={vals['card_total']:.2f} covers={vals['covers']} grats={vals['gratuities']:.2f}")
        if DRY_RUN:
            continue
        # epos_daily_reports has no `site` column — site is encoded via entity_id
        # (malthouse=1=pub, sandwich=2=cafe), matching frontend_today_gross.
        ent = 1 if site == "malthouse" else 2
        async with conn.transaction():
            await conn.execute("SELECT set_config('app.current_entity', $1, true)", str(ent))
            await conn.execute("SELECT set_config('app.current_realm', 'work', true)")
            await conn.execute("""
                INSERT INTO epos_daily_reports
                    (report_date, session, gross_sales, net_sales,
                     cash_total, card_total, covers, gratuities,
                     refunds, voids, accommodation_sales,
                     idempotency_key, created_at, entity_id, realm)
                VALUES ($1,'day',$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,NOW(),$12,'work')
                ON CONFLICT (idempotency_key) DO UPDATE SET
                    gross_sales=EXCLUDED.gross_sales, net_sales=EXCLUDED.net_sales,
                    cash_total=EXCLUDED.cash_total, card_total=EXCLUDED.card_total,
                    covers=EXCLUDED.covers, gratuities=EXCLUDED.gratuities,
                    refunds=EXCLUDED.refunds, voids=EXCLUDED.voids,
                    accommodation_sales=EXCLUDED.accommodation_sales
            """, dt, vals["gross_sales"], vals["net_sales"],
                 vals["cash_total"], vals["card_total"], vals["covers"],
                 vals["gratuities"], vals["refunds"], vals["voids"],
                 vals["accommodation_sales"], key, ent)
    await conn.close()
    print(f"Done. {len(dates)} site-dates processed.")

asyncio.run(run())
