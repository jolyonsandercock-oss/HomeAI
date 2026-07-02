#!/usr/bin/env python3
"""Fix labour % green — replace '' with emerald-400."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path, 'rb') as f:
    data = f.read()

old = b"' : '')}>{r."
new = b"' : 'text-emerald-400'})>{r."

count = data.count(old)
print(f"Matches (with space): {count}")

if count == 3:
    data = data.replace(old, new)
    with open(path, 'wb') as f:
        f.write(data)
    print("Written OK")
else:
    # Try without trailing space before colon
    old2 = b"': '')}>{r."
    count2 = data.count(old2)
    print(f"Matches (no space): {count2}")
