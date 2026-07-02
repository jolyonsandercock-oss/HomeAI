#!/usr/bin/env python3
"""Remove QuotaStatusTile from admin page."""

path = "/home_ai/services/homeai-frontend/app/admin/page.tsx"

with open(path) as f:
    content = f.read()

# Remove import
content = content.replace(
    "import { QuotaStatusTile } from '@/components/admin/QuotaStatusTile';\n",
    ""
)

# Remove section
old = """      <SandboxWrapper id="admin.quota" label="AI quota">
        <QuotaStatusTile />
      </SandboxWrapper>

"""

content = content.replace(old, "")

with open(path, "w") as f:
    f.write(content)

print("Done")
