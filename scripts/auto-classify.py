#!/usr/bin/env python3
"""Daily auto-classification — re-run rules on uncategorised vendors.
Uses psql via docker exec.
Shrinks the exception pipeline over time."""

import subprocess, sys
from datetime import datetime

DRY_RUN = "--dry-run" in sys.argv

def psql(sql):
    return subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai", "-t", "-A"],
        input=sql, capture_output=True, text=True, timeout=30
    ).stdout.strip()

print(f"{datetime.now().isoformat()} auto-classify start")

# Phase 1: Find vendors without rules that have feedback
vendors_raw = psql("""
    SELECT DISTINCT vii.vendor_domain, COALESCE(NULLIF(vii.vendor_name, ''), vii.vendor_domain) AS display
    FROM vendor_invoice_inbox vii
    WHERE (vii.category_canonical IS NULL OR vii.category_canonical = '' OR vii.category_canonical = 'other')
      AND vii.status NOT IN ('duplicate','ignored')
      AND vii.received_at > NOW() - INTERVAL '90 days'
      AND NOT EXISTS (
        SELECT 1 FROM vendor_category_rules vcr
        WHERE vii.vendor_domain ILIKE '%' || vcr.domain_pattern || '%'
           OR vcr.domain_pattern ILIKE '%' || vii.vendor_domain || '%'
      )
    LIMIT 50
""")

created = 0
if vendors_raw:
    for line in vendors_raw.split("\n"):
        line = line.strip()
        if not line or "|" not in line:
            continue
        parts = line.split("|", 1)
        domain = parts[0].strip()
        display = parts[1].strip() if len(parts) > 1 else domain
        domain_part = domain.split("@")[-1] if "@" in domain else domain
        if not domain:
            continue
        
        ds = domain.replace("'", "''")
        dps = domain_part.replace("'", "''")
        disps = display[:60].replace("'", "''")
        
        feedback = psql(f"""
            SELECT corrected_category, COUNT(*) as times
            FROM line_category_feedback lcf
            WHERE lcf.vendor_domain = '{ds}'
               OR lcf.vendor_domain ILIKE '%{dps}%'
            GROUP BY corrected_category
            ORDER BY COUNT(*) DESC
            LIMIT 1
        """)
        
        if feedback and "|" in feedback:
            cat = feedback.split("|")[0].strip()
            if cat:
                cs = cat.replace("'", "''")
                if DRY_RUN:
                    print(f"  DRY: {display} ({domain_part}) -> {cat}")
                else:
                    psql(f"""
                        INSERT INTO vendor_category_rules (domain_pattern, category, vendor_display, priority, notes, site)
                        VALUES ('{dps}', '{cs}', '{disps}', 50,
                                'Auto-classified {datetime.now().isoformat()[:10]}', 'shared')
                        ON CONFLICT (domain_pattern, site) DO UPDATE
                          SET category = EXCLUDED.category,
                              priority = LEAST(vendor_category_rules.priority, 50),
                              notes = CONCAT(vendor_category_rules.notes, '; auto-classified {datetime.now().isoformat()[:10]}')
                    """)
                    created += 1
                    print(f"  Created rule: {domain_part} -> {cat}")

print(f"  Created {created} new rules")

# Phase 2: Assign departments for high-confidence category mappings
if not DRY_RUN:
    result = psql("""
        WITH dept_updates AS (
          SELECT vil.id,
                 CASE
                   WHEN vcr.category IN ('wet_purchase','dry_purchase','cafe_stock') THEN 'kitchen'
                   WHEN vcr.category IN ('utilities','software') THEN 'overhead'
                   ELSE NULL
                 END AS new_dept
          FROM vendor_invoice_lines vil
          JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id
          JOIN vendor_category_rules vcr ON (
            vii.vendor_domain ILIKE '%' || vcr.domain_pattern || '%'
          )
          WHERE vil.department IS NULL
            AND vcr.category IN ('wet_purchase','dry_purchase','cafe_stock','utilities','software')
        )
        UPDATE vendor_invoice_lines vil
        SET department = du.new_dept
        FROM dept_updates du
        WHERE vil.id = du.id AND du.new_dept IS NOT NULL
        RETURNING vil.id
    """)
    assigned_lines = [l for l in result.split("\n") if l.strip()] if result else []
    print(f"  Assigned {len(assigned_lines)} line items to departments")
else:
    print("  DRY RUN: would assign departments")

print(f"{datetime.now().isoformat()} auto-classify complete")
