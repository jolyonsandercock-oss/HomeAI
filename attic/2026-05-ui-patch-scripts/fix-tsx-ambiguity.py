#!/usr/bin/env python3
"""Fix TSX ambiguity with > inside JSX expressions."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

for col in ['pub_labour_pct', 'cafe_labour_pct', 'combined_labour_pct']:
    old = f"(r.{col} != null && num(r.{col}) > 35 ? 'text-red-400' : r.{col} != null && num(r.{col}) > 25 ? 'text-amber-300' : 'text-emerald-400')"
    new = f"(r.{col} != null && (num(r.{col}) > 35) ? 'text-red-400' : r.{col} != null && (num(r.{col}) > 25) ? 'text-amber-300' : 'text-emerald-400')"
    n = content.count(old)
    if n == 1:
        content = content.replace(old, new)
        print(f"Fixed {col}")
    else:
        print(f"{col}: {n} matches (expected 1)")

with open(path, "w") as f:
    f.write(content)

# Verify no unescaped > issues by checking counts
lines = content.split("\n")
for i, line in enumerate(lines):
    if '> {' in line and 'className' in line:
        print(f"  Check line {i+1}: potential issue")
print("Done")
