#!/usr/bin/env python3
"""Change default labour % colour from white to emerald green."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path, 'rb') as f:
    data = f.read()

# Actual pattern: ... : ''})>{r.labour_pct
# Replace '' with 'text-emerald-400'
old = b" : ''})>{r.labour_pct"
new = b" : 'text-emerald-400'})>{r.labour_pct"

count = data.count(old)
print(f"Matches: {count}")
if count == 1:
    data = data.replace(old, new)
    with open(path, 'wb') as f:
        f.write(data)
    # Verify
    emerald = data.count(b'emerald')
    print(f"emerald occurrences: {emerald}")
    print("Done")
else:
    # Try without space before colon
    old2 = b": ''})>{r.labour_pct"
    count2 = data.count(old2)
    print(f"Without space: {count2}")
    if count2 == 1:
        data = data.replace(old2, b": 'text-emerald-400'})>{r.labour_pct")
        with open(path, 'wb') as f:
            f.write(data)
        print("Written")
