#!/usr/bin/env python3
"""Fix the bar drink classifications in the daily totals and filterable table slugs."""
import subprocess

slugs = {
    "sales_daily_totals_30d": {
        "IN ('ALCOHOL SALES','HOT DRINKS')": "IN ('ALCOHOL SALES','DRINK SALES','HOT DRINKS')"
    },
    "sales_filterable_daily_table": {
        "IN ('ALCOHOL SALES','HOT DRINKS')": "IN ('ALCOHOL SALES','DRINK SALES','HOT DRINKS')"
    }
}

for slug, replacements in slugs.items():
    # Fetch current SQL
    cmd = f"""psql -U postgres -d homeai -t -A -c "SELECT sql_template FROM query_whitelist WHERE slug='{slug}';" """
    result = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "bash", "-c", cmd],
        capture_output=True, text=True
    )
    sql = result.stdout.strip()
    
    for old, new in replacements.items():
        sql = sql.replace(old, new)
    
    # Escape single quotes in SQL for psql
    escaped = sql.replace("'", "''")
    
    update = f"UPDATE query_whitelist SET sql_template = '{escaped}' WHERE slug = '{slug}';"
    with open("/dev/stdin", "w") as f:
        pass
    
    result = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai", "-c", update],
        capture_output=True, text=True
    )
    print(f"{slug}: {result.stdout.strip()}")

print("Done")
