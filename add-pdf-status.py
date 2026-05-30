#!/usr/bin/env python3
"""Add PDF extraction status to line item modal."""

path = "/home_ai/services/homeai-frontend/app/tasks/page.tsx"

with open(path) as f:
    content = f.read()

# Add has_pdf_text to interface
content = content.replace(
    "  subject: string;\n  received_at: string;\n}",
    "  subject: string;\n  received_at: string;\n  has_pdf_text: boolean;\n}"
)

# Show message when lines exist but all have no PDF text
old_empty = '                    {lines.filter(l => !l.department).length === 0 && (\n                    <tr><td colSpan={3} className="py-2 text-center text-ink-500">All lines assigned</td></tr>\n                  )}'

new_empty = """                    {lines.filter(l => !l.department).length === 0 && (
                    <tr><td colSpan={3} className="py-2 text-center text-ink-500">
                      {lines.filter(l => !l.has_pdf_text).length > 0
                        ? 'PDF text extraction pending for some invoices (Haiku backfill)'
                        : 'All lines assigned'}
                    </td></tr>
                  )}"""

content = content.replace(old_empty, new_empty)

with open(path, "w") as f:
    f.write(content)

print("Done")
