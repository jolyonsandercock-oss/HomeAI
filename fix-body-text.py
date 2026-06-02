#!/usr/bin/env python3
"""Replace placeholder body text with actual data."""

path = "/home_ai/services/homeai-frontend/app/comms/page.tsx"

with open(path) as f:
    content = f.read()

old = "                  Loading email body..."
new = "                  {selectedTask.body_text || '(no body text available)'}"

n = content.count(old)
print(f"Found: {n}")
if n == 1:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("Done")
