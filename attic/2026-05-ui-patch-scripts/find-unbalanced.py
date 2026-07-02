#!/usr/bin/env python3
"""Find unbalanced brackets before 'return ('."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

lines = content.split("\n")
idx = content.find("return (")
pre_lines = content[:idx].split("\n")

balance = 0
for i, line in enumerate(pre_lines):
    o = line.count("(") + line.count("{") + line.count("[")
    c = line.count(")") + line.count("}") + line.count("]")
    prev = balance
    balance += o - c
    # Check for strings that might be confusing the counter
    # Count backticks
    bt = line.count("`")
    if bt % 2 != 0:
        print(f"  UNEVEN BACKTICKS line {i+1}: {line.strip()[:80]}")
    if abs(balance) > 5:
        pass  # normal inside deep nesting
    if balance != 0 and prev == 0:
        print(f"  OPEN line {i+1}: {line.strip()[:100]} (bal={balance})")
    if balance < 0:
        print(f"  CLOSE line {i+1}: {line.strip()[:80]} (bal={balance})")

print(f"\nFinal balance before return: {balance}")
