#!/usr/bin/env python3
"""Verify slug outputs after fixes."""
import urllib.request, json

def fetch(slug):
    url = f"http://localhost:3003/app/api/slug/{slug}"
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read())

# Check income slug
inc = fetch("sales_30d_income_vs_labour")
print("=== sales_30d_income_vs_labour ===")
for d in inc[:3]:
    print(f"  {d['day']}: pub_income={d['pub_income']} cafe_income={d['cafe_income']} total_income={d['total_income']}")
print(f"  ... {len(inc)} rows")

# Check filterable table
tbl = fetch("sales_filterable_daily_table")
print("\n=== sales_filterable_daily_table ===")
if tbl:
    print(f"  Columns: {list(tbl[0].keys())}")
    for d in tbl[:3]:
        print(f"  {d['day']}")
        print(f"    pub: total={d['pub_total']} food={d['pub_food']} bar={d['pub_bar']} accom={d['pub_accom']} labour={d['pub_labour']} pct={d['pub_labour_pct']}")
        print(f"    cafe: total={d['cafe_total']} ice={d['cafe_icecream']} other={d['cafe_other']} labour={d['cafe_labour']} pct={d['cafe_labour_pct']}")
        print(f"    combined: total={d['combined_total']} labour={d['combined_labour']} pct={d['combined_labour_pct']} cogs={d['cogs_overall']}")
    print(f"  ... {len(tbl)} rows")
else:
    print("  EMPTY!")

# Spot check May 25 (the known issue day)
print("\n=== Spot check: May 25 ===")
for d in inc:
    if d['day'] == '2026-05-25':
        print(f"  income: pub={d['pub_income']} cafe={d['cafe_income']} total={d['total_income']}")
for d in tbl:
    if d['day'] == '2026-05-25':
        print(f"  table pub_total={d['pub_total']} cafe_total={d['cafe_total']} combined={d['combined_total']}")
