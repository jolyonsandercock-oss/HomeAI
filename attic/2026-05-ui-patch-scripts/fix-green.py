#!/usr/bin/env python3
"""Fix labour % green colour - exact byte match."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path, "rb") as f:
    data = f.read()

# The exact byte sequence after "text-amber-300"
# From hex dump: 27 20 3a 20 27 27 29 7d 3e 7b 72 2e 6c 61 62 6f 75 72 5f 70 63 74
# Which is: ' : '')}>{r.labour_pct
target = b"' : '')"
replacement = b"' : 'text-emerald-400')"

idx = data.find(target)
print(f"Found '{target.decode()}' at offset {idx}")
if idx >= 0:
    # Verify we're in the right place (should be followed by >{r.labour_pct)
    after = data[idx+len(target):idx+len(target)+20]
    print(f"After target: {repr(after)}")
    if b'labour_pct' in after:
        data = data[:idx] + replacement + data[idx+len(target):]
        with open(path, "wb") as f:
            f.write(data)
        # Verify
        with open(path, "rb") as f:
            check = f.read()
        e_count = check.count(b"emerald")
        print(f"emerald occurrences: {e_count}")
        if e_count >= 1:
            print("SUCCESS")
        else:
            print("FAILED - no emerald found after write")
    else:
        print("Wrong context - not the labour_pct line")
