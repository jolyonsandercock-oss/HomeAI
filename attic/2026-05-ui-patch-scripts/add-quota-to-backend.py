#!/usr/bin/env python3
"""Add QuotaStatusTile to backend page."""

path = "/home_ai/services/homeai-frontend/app/backend/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add import
content = content.replace(
    "from 'lucide-react';",
    "from 'lucide-react';\nimport { QuotaStatusTile } from '@/components/admin/QuotaStatusTile';"
)

# 2. Add the quota section after the stale alert, before the freshness section
old = """      )}

      <SandboxWrapper id=\"backend.freshness\""""

new = """      )}

      <SandboxWrapper id=\"backend.quota\" label=\"AI quota\">
        <QuotaStatusTile />
      </SandboxWrapper>

      <SandboxWrapper id=\"backend.freshness\""""

content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)

print("Done")
