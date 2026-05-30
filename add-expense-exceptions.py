#!/usr/bin/env python3
"""Add expense exceptions section to tasks page."""

path = "/home_ai/services/homeai-frontend/app/tasks/page.tsx"

with open(path) as f:
    content = f.read()

# Add gbp format import
content = content.replace(
    "import { useSlug } from '@/lib/hooks';",
    "import { useSlug } from '@/lib/hooks';\nimport { gbp } from '@/lib/format';"
)

# Add ExpenseExceptionRow interface after ActionRow
old_interfaces = """interface ActionRow {
  source: string;
  ref: string;
  severity: 'critical' | 'high' | 'medium' | 'low' | null;
  kind: string;
  title: string;
  age_date: string;
  age_days: number;
  realm: string;
}"""

new_interfaces = """interface ActionRow {
  source: string;
  ref: string;
  severity: 'critical' | 'high' | 'medium' | 'low' | null;
  kind: string;
  title: string;
  age_date: string;
  age_days: number;
  realm: string;
}

interface ExpenseExceptionRow {
  kind: string;
  vendor_domain: string;
  vendor_display: string;
  invoice_count: number;
  total_gross: string;
  last_seen: string;
  detail: string;
}"""

content = content.replace(old_interfaces, new_interfaces)

# Add the expense exceptions slug and section after the queue section
old_section_end = """          ) : (
            <PlaceholderState message=\"No open actions.\" />
          )}
        </Section>
      </SandboxWrapper>
    </div>
  );
}"""

new_section_end = """          ) : (
            <PlaceholderState message=\"No open actions.\" />
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id=\"tasks.expense-exceptions\" label=\"Expense exceptions\">
        <ExpenseExceptionSection />
      </SandboxWrapper>
    </div>
  );
}

function ExpenseExceptionSection() {
  const exc = useSlug<ExpenseExceptionRow>('expense_tasks_exceptions', {}, { refetchInterval: 5 * 60_000 });
  const data = exc.data ?? [];
  
  const uncatVendors = data.filter(d => d.kind === 'uncategorised_vendor');
  const unassignedLines = data.filter(d => d.kind === 'unassigned_line');
  const uncatGross = uncatVendors.reduce((a, r) => a + parseFloat(r.total_gross), 0);
  const unassignGross = unassignedLines.reduce((a, r) => a + parseFloat(r.total_gross), 0);

  return (
    <div className=\"space-y-4\">
      {exc.isLoading ? (
        <PlaceholderState message=\"Loading expense exceptions…\" />
      ) : data.length === 0 ? (
        <PlaceholderState message=\"No uncategorised vendors or unassigned line items.\" />
      ) : (
        <>
          <div className=\"grid grid-cols-2 sm:grid-cols-4 gap-3\">
            <KPICard label=\"Uncat. vendors\" value={uncatVendors.length} />
            <KPICard label=\"Uncat. £\" value={gbp(uncatGross)} />
            <KPICard label=\"Unassigned lines\" value={unassignedLines.length} />
            <KPICard label=\"Unassigned £\" value={gbp(unassignGross)} />
          </div>

          {uncatVendors.length > 0 && (
            <Section title={`Uncategorised vendors (${uncatVendors.length}) — needs domain rule in vendor_category_rules`}>
              <div className=\"tile overflow-x-auto text-xs\">
                <table className=\"w-full font-mono\">
                  <thead className=\"text-ink-500 uppercase tracking-wider\">
                    <tr>
                      <th className=\"text-left py-1.5\">Vendor</th>
                      <th className=\"text-right\">Invoices</th>
                      <th className=\"text-right\">Total £</th>
                      <th className=\"text-right\">Current cat.</th>
                      <th className=\"text-right\">Last seen</th>
                    </tr>
                  </thead>
                  <tbody>
                    {uncatVendors.slice(0, 15).map(r => (
                      <tr key={r.vendor_domain + r.detail} className=\"border-t border-ink-200\">
                        <td className=\"py-1.5 text-ink-900\">{r.vendor_display}</td>
                        <td className=\"text-right text-ink-500\">{r.invoice_count}</td>
                        <td className=\"text-right text-warn\">{gbp(parseFloat(r.total_gross))}</td>
                        <td className=\"text-right text-ink-500\">{r.detail}</td>
                        <td className=\"text-right text-ink-500\">{new Date(r.last_seen).toLocaleDateString('en-GB', {day:'numeric', month:'short'})}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </Section>
          )}

          {unassignedLines.length > 0 && (
            <Section title={`Unassigned line items (${unassignedLines.length}) — needs department assignment`}>
              <div className=\"tile overflow-x-auto text-xs\">
                <table className=\"w-full font-mono\">
                  <thead className=\"text-ink-500 uppercase tracking-wider\">
                    <tr>
                      <th className=\"text-left py-1.5\">Vendor</th>
                      <th className=\"text-left\">Description</th>
                      <th className=\"text-right\">Qty</th>
                      <th className=\"text-right\">Total £</th>
                    </tr>
                  </thead>
                  <tbody>
                    {unassignedLines.slice(0, 20).map((r, i) => (
                      <tr key={r.vendor_domain + r.detail + i} className=\"border-t border-ink-200\">
                        <td className=\"py-1.5 text-ink-700\">{r.vendor_display.slice(0, 25)}</td>
                        <td className=\"text-ink-900\">{r.detail}</td>
                        <td className=\"text-right text-ink-500\">{r.invoice_count}</td>
                        <td className=\"text-right text-amber-400\">{gbp(parseFloat(r.total_gross))}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </Section>
          )}
        </>
      )}
    </div>
  );
}"""

content = content.replace(old_section_end, new_section_end)

with open(path, "w") as f:
    f.write(content)

print("tasks/page.tsx updated")
