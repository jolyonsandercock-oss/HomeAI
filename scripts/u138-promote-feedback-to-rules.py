#!/usr/bin/env python3
"""
u138-promote-feedback-to-rules.py
=================================
Nightly job: read line_category_feedback, find (vendor_domain, value) groups
with ≥3 agreeing corrections, and promote them so future invoices auto-apply.

Run via cron / n8n schedule trigger, or manually inside any service container
that has asyncpg installed (build-dashboard, bot-responder, llm-router, etc.):

  docker exec -e PG_DSN="postgresql://postgres:PW@homeai-postgres:5432/homeai" \\
              homeai-build-dashboard python - --dry-run < scripts/u138-promote-feedback-to-rules.py

Promotion rules:
- ≥N feedback rows agreeing on a (vendor_domain, family) pair → INSERT
  into line_family_rules (created if not exists).
- ≥N feedback rows agreeing on a (vendor_domain, department) pair → UPDATE
  vendor_invoice_lines.department for all un-coded lines from that vendor.
- Feedback older than --max-age-days is discarded.

Exits 0 on clean run, 1 on failure.
"""

import argparse
import asyncio
import os
import sys
from collections import Counter, defaultdict

import asyncpg


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--dry-run", action="store_true",
                   help="Print planned promotions without writing.")
    p.add_argument("--min-agreement", type=int, default=3,
                   help="Minimum feedback rows agreeing on a value to promote (default 3).")
    p.add_argument("--max-age-days", type=int, default=30,
                   help="Discard feedback older than N days (default 30).")
    return p.parse_args()


async def amain():
    args = parse_args()

    dsn = os.environ.get("PG_DSN")
    if not dsn:
        print("FAIL: PG_DSN env var not set", file=sys.stderr)
        return 1

    conn = await asyncpg.connect(dsn)
    try:
        await conn.execute("SELECT home_ai.set_realm('owner')")

        rows = await conn.fetch("""
            SELECT vendor_domain,
                   corrected_department,
                   corrected_family
              FROM line_category_feedback
             WHERE corrected_at > NOW() - ($1 || ' days')::interval
               AND source IN ('manual','nightly_haiku')
        """, str(args.max_age_days))

        family_votes: dict[str, Counter] = defaultdict(Counter)
        dept_votes:   dict[str, Counter] = defaultdict(Counter)
        for r in rows:
            vd = (r["vendor_domain"] or "").strip().lower()
            if not vd:
                continue
            if r["corrected_family"]:
                family_votes[vd][r["corrected_family"].strip()] += 1
            if r["corrected_department"]:
                dept_votes[vd][r["corrected_department"]] += 1

        family_promotions = [
            (vd, fam, cnt)
            for vd, ctr in family_votes.items()
            for fam, cnt in ctr.items()
            if cnt >= args.min_agreement
        ]
        dept_backfills = [
            (vd, dept, cnt)
            for vd, ctr in dept_votes.items()
            for dept, cnt in ctr.items()
            if cnt >= args.min_agreement
        ]

        print(f"feedback_rows={len(rows)}  "
              f"family_promotions={len(family_promotions)}  "
              f"dept_backfills={len(dept_backfills)}")
        for vd, fam, cnt in family_promotions:
            print(f"  family: {vd!r:>40} -> {fam!r:<20} (x{cnt})")
        for vd, dept, cnt in dept_backfills:
            print(f"  dept:   {vd!r:>40} -> {dept!r:<10} (x{cnt})")

        if args.dry_run:
            print("--dry-run: no DB writes")
            return 0

        async with conn.transaction():
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS line_family_rules (
                  id              bigserial PRIMARY KEY,
                  vendor_domain   text NOT NULL,
                  family          text NOT NULL,
                  agreement_count integer NOT NULL DEFAULT 0,
                  source          text NOT NULL DEFAULT 'promoter',
                  created_at      timestamptz NOT NULL DEFAULT NOW(),
                  updated_at      timestamptz NOT NULL DEFAULT NOW(),
                  UNIQUE (vendor_domain, family)
                )
            """)

            promoted_fam = 0
            for vd, fam, cnt in family_promotions:
                await conn.execute("""
                    INSERT INTO line_family_rules
                                (vendor_domain, family, agreement_count, source)
                         VALUES ($1, $2, $3, 'promoter')
                    ON CONFLICT (vendor_domain, family) DO UPDATE
                      SET agreement_count = EXCLUDED.agreement_count,
                          updated_at      = NOW()
                """, vd, fam, cnt)
                promoted_fam += 1

            backfilled = 0
            for vd, dept, cnt in dept_backfills:
                result = await conn.execute("""
                    UPDATE vendor_invoice_lines vil
                       SET department = $1
                      FROM vendor_invoice_inbox vii
                     WHERE vii.id = vil.invoice_id
                       AND vii.vendor_domain = $2
                       AND vil.department IS NULL
                """, dept, vd)
                # asyncpg returns "UPDATE N"
                try:
                    n = int(result.split()[-1])
                except Exception:
                    n = 0
                backfilled += n
                print(f"  dept backfill {vd!r}->{dept!r}: updated {n} lines")

        print(f"DONE: promoted {promoted_fam} family rules; backfilled {backfilled} line departments.")
        return 0
    finally:
        await conn.close()


def main():
    try:
        return asyncio.run(amain())
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
