#!/usr/bin/env python3
"""Fix TSX ambiguity with > inside JSX expressions - exact match."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

# The issue: > in > 35 ? and > 25 ? inside JSX {} expressions confuse the parser
# Fix: wrap numeric comparisons in parens so the > isn't ambiguous

for col in ['pub_labour_pct', 'cafe_labour_pct', 'combined_labour_pct']:
    old_num = f"num(r.{col}) > 35"
    new_num = f"(num(r.{col}) > 35)"
    content = content.replace(old_num, new_num)
    
    old_num2 = f"num(r.{col}) > 25"
    new_num2 = f"(num(r.{col}) > 25)"
    content = content.replace(old_num2, new_num2)
    
    print(f"{col}: replaced > 35 and > 25")

with open(path, "w") as f:
    f.write(content)

# Quick check
lines = content.split("\n")
for col in ['pub_labour_pct', 'cafe_labour_pct', 'combined_labour_pct']:
    for i, line in enumerate(lines):
        if col in line and '> 35' in line and 'num' in line:
            print(f"  {col} on line {i+1}")
            break

print("Done")
