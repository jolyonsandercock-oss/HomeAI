#!/usr/bin/env python3
"""Fix the 'figures are for' warning text on dashboard."""

path = "/home_ai/services/homeai-frontend/app/page.tsx"

with open(path, 'rb') as f:
    data = f.read()

# Fix 1: the asOf comparison — slice to 10 chars for date-only comparison
old_compare = b"if (!asOf || asOf === today) return null;"
new_compare = b"if (!asOf || asOf.slice(0, 10) === today) return null;"
n = data.count(old_compare)
print(f"Compare line: {n} matches")
if n == 1:
    data = data.replace(old_compare, new_compare)

# Fix 2: the warning message
old_warn = b'<div className="mt-1 text-sm text-red-400 flex items-center gap-1">\n                    \xe2\x9a\xa0 figures are for {asOf} (no till data for today yet)\n                  </div>'
new_warn = b'<div className="mt-1 text-sm text-ink-500 flex items-center gap-1">\n                    showing latest till data from {asOf.slice(0, 10)} \xe2\x80\x94 today not yet polled\n                  </div>'
n = data.count(old_warn)
print(f"Warning message: {n} matches")
if n == 1:
    data = data.replace(old_warn, new_warn)

with open(path, 'wb') as f:
    f.write(data)

print("Done")
