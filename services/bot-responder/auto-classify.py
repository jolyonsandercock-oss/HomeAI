#!/usr/bin/env python3
"""Daily auto-classification — re-run rules on uncategorised vendors.
Scans for vendors without category rules, applies rules from accumulated feedback.
As rules accumulate, the exception pipeline shrinks."""

import asyncio, asyncpg, os, sys
from datetime import datetime

PG_DSN = os.environ.get("PG_DSN", "postgresql://postgres@homeai-postgres/homeai")
DRY_RUN = "--dry-run" in sys.argv

def NOW():
    return datetime.utcnow()

async def main():
    conn = await asyncpg.connect(PG_DSN)
    print(f"{NOW().isoformat()} — auto-classify start")
    
    # 1. Find uncategorised vendors with no existing rule
    vendors = await conn.fetch("""
        SELECT DISTINCT v.vendor_domain,
               COALESCE(NULLIF(v.vendor_name, ''), v.vendor_domain) AS display
        FROM vendor_invoice_inbox v
        WHERE (v.category_canonical IS NULL OR v.category_canonical = '' OR v.category_canonical = 'other')
          AND v.status NOT IN ('duplicate','ignored')
          AND NOT EXISTS (
            SELECT 1 FROM vendor_category_rules r
            WHERE v.vendor_domain ILIKE '%' || r.domain_pattern || '%'
               OR r.domain_pattern ILIKE '%' || v.vendor_domain || '%'
          )
        ORDER BY v.vendor_domain
    """)
    
    print(f"  Found {len(vendors)} uncategorised vendors without rules")
    
    created = 0
    for v in vendors:
        vendor_domain = v["vendor_domain"]
        display = v["display"]
        domain_part = vendor_domain.split("@")[-1] if "@" in vendor_domain else vendor_domain
        
        # Check feedback table for any corrections on this vendor
        feedback = await conn.fetchrow("""
            SELECT corrected_category, COUNT(*) as times
            FROM line_category_feedback lcf
            WHERE lcf.vendor_domain = $1
               OR lcf.vendor_domain ILIKE '%' || $2 || '%'
            GROUP BY corrected_category
            ORDER BY COUNT(*) DESC
            LIMIT 1
        """, vendor_domain, domain_part)
        
        if feedback and feedback["corrected_category"]:
            cat = feedback["corrected_category"]
            if DRY_RUN:
                print(f"    DRY: would create rule for {display} -> {cat}")
            else:
                await conn.execute("""
                    INSERT INTO vendor_category_rules (domain_pattern, category, vendor_display, priority, notes, site)
                    VALUES ($1, $2, $3, 50, $4, 'shared')
                    ON CONFLICT (domain_pattern, site) DO UPDATE
                      SET category = EXCLUDED.category,
                          priority = LEAST(vendor_category_rules.priority, 50),
                          notes = vendor_category_rules.notes || '; auto-classified ' || NOW()::date::text
                """, domain_part, cat, display[:60],
                    f"Auto-classified {NOW().date()}: matched from {feedback['times']} feedback entries")
                created += 1
                print(f"    Created rule: {display} -> {cat}")
    
    print(f"  Created {created} new rules")
    
    # 2. Auto-assign departments from vendor category rules
    result = await conn.execute("""
        UPDATE vendor_invoice_lines vil
        SET department = CASE
          WHEN vcr.category IN ('wet_purchase','dry_purchase','cafe_stock') THEN 'kitchen'
          WHEN vcr.category IN ('utilities','software','repairs_maintenance') THEN 'overhead'
          WHEN vcr.category = 'income' THEN 'overhead'
          ELSE 'overhead'
        END
        FROM vendor_invoice_inbox vii
        JOIN vendor_category_rules vcr ON (
          vii.vendor_domain ILIKE '%' || vcr.domain_pattern || '%'
          OR vcr.domain_pattern ILIKE '%' || vii.vendor_domain || '%'
        )
        WHERE vil.invoice_id = vii.id
          AND vil.department IS NULL
          AND vcr.category IS NOT NULL
          AND vcr.category != ''
    """)
    # Extract count from UPDATE result
    print(f"  Auto-assigned departments (from rules)")
    
    print(f"{NOW().isoformat()} — auto-classify complete")
    await conn.close()

if __name__ == "__main__":
    asyncio.run(main())
