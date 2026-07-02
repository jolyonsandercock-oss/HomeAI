#!/usr/bin/env python3
"""Add site filter, realm/business area; improve modal info."""

path = "/home_ai/services/homeai-frontend/app/tasks/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add site to ExpenseExceptionRow interface
content = content.replace(
    "interface ExpenseExceptionRow {\n  kind: string;\n  line_id: number | null;\n  vendor_domain: string;\n  vendor_display: string;\n  invoice_count: number;\n  total_gross: string;\n  last_seen: string;\n  detail: string;\n}",
    "interface ExpenseExceptionRow {\n  kind: string;\n  line_id: number | null;\n  vendor_domain: string;\n  vendor_display: string;\n  invoice_count: number;\n  total_gross: string;\n  last_seen: string;\n  detail: string;\n  site: string;\n}"
)

# 2. Add site filter state + filtered data inside ExpenseExceptionSection
old_section_start = """function ExpenseExceptionSection() {
  const [selectedRow, setSelectedRow] = useState<ExpenseExceptionRow | null>(null);
  const exc = useSlug<ExpenseExceptionRow>('expense_tasks_exceptions', {}, { refetchInterval: 5 * 60_000 });
  const data = exc.data ?? [];
  
  const uncatVendors = data.filter(d => d.kind === 'uncategorised_vendor');
  const unassignedLines = data.filter(d => d.kind === 'unassigned_line');
  const uncatGross = uncatVendors.reduce((a, r) => a + parseFloat(r.total_gross), 0);
  const unassignGross = unassignedLines.reduce((a, r) => a + parseFloat(r.total_gross), 0);"""

new_section_start = """function ExpenseExceptionSection() {
  const [selectedRow, setSelectedRow] = useState<ExpenseExceptionRow | null>(null);
  const [siteFilter, setSiteFilter] = useState('all');
  const exc = useSlug<ExpenseExceptionRow>('expense_tasks_exceptions', {}, { refetchInterval: 5 * 60_000 });
  const data = exc.data ?? [];
  
  const filtered = data.filter(d => siteFilter === 'all' || d.site === siteFilter);
  const uncatVendors = filtered.filter(d => d.kind === 'uncategorised_vendor');
  const unassignedLines = filtered.filter(d => d.kind === 'unassigned_line');
  const uncatGross = uncatVendors.reduce((a, r) => a + parseFloat(r.total_gross), 0);
  const unassignGross = unassignedLines.reduce((a, r) => a + parseFloat(r.total_gross), 0);
  const sites = [...new Set(data.map(d => d.site || 'shared'))].sort();"""

content = content.replace(old_section_start, new_section_start)

# 3. Add filter bar above the KPI cards in the expense section
old_expense_start = """          <div className=\"grid grid-cols-2 sm:grid-cols-4 gap-3\">
            <KPICard label=\"Uncat. vendors\" value={uncatVendors.length} />
            <KPICard label=\"Uncat. £\" value={gbp(uncatGross)} />
            <KPICard label=\"Unassigned lines\" value={unassignedLines.length} />
            <KPICard label=\"Unassigned £\" value={gbp(unassignGross)} />
          </div>"""

new_expense_start = """          <div className=\"mb-2 flex items-center gap-2 text-xs\">
            <span className=\"text-ink-500\">Business area:</span>
            <select value={siteFilter} onChange={(e) => setSiteFilter(e.target.value)}
              className=\"bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1\">
              <option value=\"all\">All</option>
              {sites.map(s => <option key={s} value={s}>{s}</option>)}
            </select>
            <span className=\"text-ink-400\">|</span>
            <span className=\"text-ink-500\">{filtered.length} items</span>
          </div>
          <div className=\"grid grid-cols-2 sm:grid-cols-4 gap-3\">
            <KPICard label=\"Uncat. vendors\" value={uncatVendors.length} />
            <KPICard label=\"Uncat. £\" value={gbp(uncatGross)} />
            <KPICard label=\"Unassigned lines\" value={unassignedLines.length} />
            <KPICard label=\"Unassigned £\" value={gbp(unassignGross)} />
          </div>"""

content = content.replace(old_expense_start, new_expense_start)

# 4. Add site info to the modal detail section
old_modal_info = """        <div className=\"space-y-2 text-xs text-ink-600 mb-4\">
          <p><span className=\"text-ink-500\">Vendor:</span> {row.vendor_display}</p>
          <p><span className=\"text-ink-500\">Detail:</span> {row.detail}</p>
          <p><span className=\"text-ink-500\">Amount:</span> {gbp(parseFloat(row.total_gross))}</p>
        </div>"""

new_modal_info = """        <div className=\"space-y-2 text-xs text-ink-600 mb-4\">
          <p><span className=\"text-ink-500\">Vendor:</span> {row.vendor_display}</p>
          <p><span className=\"text-ink-500\">Detail:</span> {row.detail}</p>
          <p><span className=\"text-ink-500\">Amount:</span> {gbp(parseFloat(row.total_gross))}</p>
          <p><span className=\"text-ink-500\">Business area:</span> {row.site || 'shared'}</p>
        </div>"""

content = content.replace(old_modal_info, new_modal_info)

with open(path, "w") as f:
    f.write(content)

print("tasks/page.tsx updated")
