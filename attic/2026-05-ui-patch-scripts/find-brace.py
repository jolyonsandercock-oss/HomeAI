#!/usr/bin/env python3
"""Find the unbalanced curly brace."""

path = "/home_ai/services/homeai-frontend/app/comms/page.tsx"

with open(path) as f:
    lines = f.readlines()

bal = 0
for i in range(0, 136):  # up to line 136 (0-indexed to just before return)
    l = lines[i]
    opens = l.count('{')
    closes = l.count('}')
    bal += opens - closes
    if bal > 1 and i > 84:
        print(f"L{i+1}: bal={bal} after {repr(l.strip()[:80])}")

print(f"\nFinal balance at line 136: {bal}")
