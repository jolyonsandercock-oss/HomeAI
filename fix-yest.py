#!/usr/bin/env python3
"""Fix 'yest' → 'yesterday' in all department page dateParam code."""

for page in ['rooms', 'restaurant', 'bar', 'cafe', 'staff']:
    path = f"/home_ai/services/homeai-frontend/app/{page}/page.tsx"
    with open(path) as f:
        content = f.read()
    content = content.replace("'yest'", "'yesterday'")
    with open(path, 'w') as f:
        f.write(content)
    print(f"{page}: fixed")
