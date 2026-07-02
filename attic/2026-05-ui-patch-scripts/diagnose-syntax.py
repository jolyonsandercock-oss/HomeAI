#!/usr/bin/env python3
"""Diagnose why the JSX parser fails at line 161."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

idx = content.find("return (")
pre = content[:idx]

opens = pre.count("(") + pre.count("{") + pre.count("[")
closes = pre.count(")") + pre.count("}") + pre.count("]")
print(f"Before 'return (': opens={opens} closes={closes} diff={opens-closes}")

# Check backticks (template literals)
bt = pre.count("`")
print(f"Backticks before return: {bt} (should be even)")

# Find unbalanced content
lines = content.split("\n")
print(f"\nTotal lines: {len(lines)}")

# Check around the problem area
print("\n--- Surrounding return ---")
for i in range(max(0, idx-200), min(len(content), idx+300)):
    pass

# Print lines 145-170 with counts
for i in range(144, 170):
    line = lines[i]
    o = line.count("(") + line.count("{") + line.count("[")
    c = line.count(")") + line.count("}") + line.count("]")
    bt = line.count("`")
    markers = []
    if o != c:
        markers.append(f"o{+o-c}")
    if bt % 2 != 0:
        markers.append(f"bt:{bt}")
    marker_str = " <-- " + ", ".join(markers) if markers else ""
    print(f"{i+1:4d} {line}{marker_str}")
