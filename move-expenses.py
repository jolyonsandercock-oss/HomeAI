#!/usr/bin/env python3
"""Add ExpenseRollup component to backend page, remove from admin page."""

backend = "/home_ai/services/homeai-frontend/app/backend/page.tsx"
admin = "/home_ai/services/homeai-frontend/app/admin/page.tsx"

# === BACKEND: add import and section ===
with open(backend) as f:
    content = f.read()

# Add import
content = content.replace(
    "import { QuotaStatusTile } from '@/components/admin/QuotaStatusTile';",
    "import { QuotaStatusTile } from '@/components/admin/QuotaStatusTile';\nimport { ExpenseRollup } from '@/components/admin/ExpenseRollup';"
)

# Add section after quota, before freshness
old = """      <SandboxWrapper id=\"backend.quota\" label=\"AI quota\">
        <QuotaStatusTile />
      </SandboxWrapper>

      <SandboxWrapper id=\"backend.freshness\""""

new = """      <SandboxWrapper id=\"backend.quota\" label=\"AI quota\">
        <QuotaStatusTile />
      </SandboxWrapper>

      <SandboxWrapper id=\"backend.expense-rollup\" label=\"Expense rollup\">
        <ExpenseRollup />
      </SandboxWrapper>

      <SandboxWrapper id=\"backend.freshness\""""

content = content.replace(old, new)

with open(backend, "w") as f:
    f.write(content)
print("backend/page.tsx updated")

# === ADMIN: remove the expense section ===
with open(admin) as f:
    content = f.read()

# Remove the import
content = content.replace(
    "import { ExpenseRollup } from '@/components/admin/ExpenseRollup';\n",
    ""
)

# Remove the SandboxWrapper section
old_admin = """      <SandboxWrapper id=\"admin.expense-rollup\" label=\"Expense rollup\">
        <ExpenseRollup />
      </SandboxWrapper>

"""

content = content.replace(old_admin, "")

with open(admin, "w") as f:
    f.write(content)
print("admin/page.tsx updated")
