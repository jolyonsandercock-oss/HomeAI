#!/usr/bin/env python3
"""Update modal to show all line items for the vendor when clicking unassigned lines."""

path = "/home_ai/services/homeai-frontend/app/tasks/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add line detail interface
content = content.replace(
    "interface ExpenseExceptionRow {",
    "interface LineDetail {\n  line_id: number;\n  invoice_id: number;\n  description: string;\n  line_gross: string;\n  department: string | null;\n  extracted_by: string | null;\n  subject: string;\n  received_at: string;\n}\n\ninterface ExpenseExceptionRow {"
)

# 2. Add the line fetch + detail view inside the modal (after site state)
old_modal_state = """  const [category, setCategory] = useState('');
  const [site, setSite] = useState('');
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState('');"""

new_modal_state = """  const [category, setCategory] = useState('');
  const [site, setSite] = useState('');
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState('');
  const [lines, setLines] = useState<LineDetail[] | null>(null);
  const [loadingLines, setLoadingLines] = useState(false);
  const [lineAssignments, setLineAssignments] = useState<Record<number, { dept: string; cat: string }>>({});

  // Fetch line items when modal opens for unassigned_line
  useEffect(() => {
    if (row?.kind === 'unassigned_line' && row.vendor_domain && !lines && !loadingLines) {
      setLoadingLines(true);
      fetch('/app/api/slug/expense_invoice_lines_for_vendor?vendor_domain=' + encodeURIComponent(row.vendor_domain))
        .then(r => r.json())
        .then(data => {
          setLines(Array.isArray(data) ? data : []);
          setLoadingLines(false);
        })
        .catch(() => { setLoadingLines(false); });
    }
  }, [row]);"""

content = content.replace(old_modal_state, new_modal_state)

# 3. Update the info section to show line count when lines loaded
old_info_section = """        <div className=\"space-y-2 text-xs text-ink-600 mb-4\">
          <p><span className=\"text-ink-500\">Vendor:</span> {row.vendor_display}</p>
          <p><span className=\"text-ink-500\">Detail:</span> {row.detail}</p>
          <p><span className=\"text-ink-500\">Amount:</span> {gbp(parseFloat(row.total_gross))}</p>
        </div>"""

new_info_section = """        <div className=\"space-y-2 text-xs text-ink-600 mb-4\">
          <p><span className=\"text-ink-500\">Vendor:</span> {row.vendor_display}</p>
          {row.kind === 'unassigned_line' && lines ? (
            <p><span className=\"text-ink-500\">Lines:</span> {lines.length} line items from this vendor</p>
          ) : (
            <>
              <p><span className=\"text-ink-500\">Detail:</span> {row.detail}</p>
              <p><span className=\"text-ink-500\">Amount:</span> {gbp(parseFloat(row.total_gross))}</p>
            </>
          )}
        </div>"""

content = content.replace(old_info_section, new_info_section)

# 4. Replace the single dropdown section with a line-by-line table when lines are loaded
old_dropdowns = """        <div className=\"space-y-3\">
          <div>
            <label className=\"block text-xs text-ink-500 mb-1\">Business area</label>
            <select value={site} onChange={(e) => setSite(e.target.value)}
              className=\"w-full bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 text-xs\">
              <option value=\"\"> unchanged</option>
              <option value=\"shared\">Shared</option>
              <option value=\"pub\">Pub</option>
              <option value=\"cafe\">Cafe</option>
            </select>
          </div>
          <div>
            <label className=\"block text-xs text-ink-500 mb-1\">Department</label>
            <select value={dept} onChange={(e) => setDept(e.target.value)}
              className=\"w-full bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 text-xs\">
              <option value=\"\"> unchanged</option>
              <option value=\"bar\">Bar</option>
              <option value=\"kitchen\">Kitchen</option>
              <option value=\"rooms\">Rooms</option>
              <option value=\"cafe\">Cafe</option>
              <option value=\"overhead\">Overhead</option>
            </select>
          </div>
          <div>
            <label className=\"block text-xs text-ink-500 mb-1\">Category</label>
            <select value={category} onChange={(e) => setCategory(e.target.value)}
              className=\"w-full bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 text-xs\">
              <option value=\"\"> unchanged</option>
              <option value=\"Beverage\">Beverage</option>
              <option value=\"Bookings\">Bookings</option>
              <option value=\"Food\">Food</option>
              <option value=\"Laundry\">Laundry</option>
              <option value=\"Maintenance\">Maintenance</option>
              <option value=\"Other\">Other</option>
            </select>
          </div>
        </div>"""

new_dropdowns = """        {row.kind === 'unassigned_line' && lines ? (
          /* Line-by-line view */
          <div className=\"space-y-2 max-h-80 overflow-y-auto\">
            <div className=\"text-xs text-ink-500 mb-1 font-medium\">Line items from {row.vendor_display}</div>
            {loadingLines ? (
              <div className=\"text-xs text-ink-500\">Loading lines...</div>
            ) : (
              <table className=\"w-full text-xs font-mono\">
                <thead className=\"text-ink-500 uppercase tracking-wider text-2xs\">
                  <tr>
                    <th className=\"text-left py-1\">Description</th>
                    <th className=\"text-right py-1\">Amount</th>
                    <th className=\"text-right py-1\">Dept</th>
                  </tr>
                </thead>
                <tbody>
                  {lines.filter(l => !l.department).map(l => (
                    <tr key={l.line_id} className=\"border-t border-ink-200\">
                      <td className=\"py-1 pr-2 text-ink-800 max-w-[200px] truncate\" title={l.description}>{l.description}</td>
                      <td className=\"py-1 text-right text-ink-500\">{gbp(parseFloat(l.line_gross))}</td>
                      <td className=\"py-1\">
                        <select value={lineAssignments[l.line_id]?.dept || ''} 
                          onChange={(e) => setLineAssignments(prev => ({ ...prev, [l.line_id]: { ...prev[l.line_id], dept: e.target.value, cat: prev[l.line_id]?.cat || '' } }))}
                          className=\"bg-ink-100 border border-ink-200 text-ink-800 rounded px-1 py-0.5 text-2xs w-20\">
                          <option value=\"\">-</option>
                          <option value=\"bar\">Bar</option>
                          <option value=\"kitchen\">Kitchen</option>
                          <option value=\"rooms\">Rooms</option>
                          <option value=\"cafe\">Cafe</option>
                          <option value=\"overhead\">Overhead</option>
                        </select>
                      </td>
                    </tr>
                  ))}
                  {lines.filter(l => !l.department).length === 0 && (
                    <tr><td colSpan={3} className=\"py-2 text-center text-ink-500\">All lines assigned</td></tr>
                  )}
                </tbody>
              </table>
            )}
          </div>
        ) : (
          /* Single-item view for vendors */
          <div className=\"space-y-3\">
            <div>
              <label className=\"block text-xs text-ink-500 mb-1\">Business area</label>
              <select value={site} onChange={(e) => setSite(e.target.value)}
                className=\"w-full bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 text-xs\">
                <option value=\"\"> unchanged</option>
                <option value=\"shared\">Shared</option>
                <option value=\"pub\">Pub</option>
                <option value=\"cafe\">Cafe</option>
              </select>
            </div>
            <div>
              <label className=\"block text-xs text-ink-500 mb-1\">Category</label>
              <select value={category} onChange={(e) => setCategory(e.target.value)}
                className=\"w-full bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 text-xs\">
                <option value=\"\"> unchanged</option>
                <option value=\"Beverage\">Beverage</option>
                <option value=\"Bookings\">Bookings</option>
                <option value=\"Food\">Food</option>
                <option value=\"Laundry\">Laundry</option>
                <option value=\"Maintenance\">Maintenance</option>
                <option value=\"Other\">Other</option>
              </select>
            </div>
          </div>
        )}"""

content = content.replace(old_dropdowns, new_dropdowns)

# 5. Update the Assign handler to batch-post line assignments
old_assign_handler = """  const handleAssign = async () => {
    if (!dept && !category) { setMessage('Select at least one'); return; }
    setSaving(true);
    setMessage('');"""

new_assign_handler = """  const handleAssign = async () => {
    setSaving(true);
    setMessage('');"""

content = content.replace(old_assign_handler, new_assign_handler)

# 6. Replace the unassigned_line branch to batch submit
old_line_branch = """      if (row.kind === 'unassigned_line' && row.line_id) {
        const res = await fetch('/app/api/feedback/line', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            line_id: row.line_id,
            corrected_department: dept || null,
            corrected_category: category || null,
            corrected_by: 'jo',
          }),
        });
        const data = await res.json();
        if (data.ok) {
          setMessage('Assigned! Refreshing...');
          setTimeout(onClose, 1200);
        } else {
          setMessage('Error: ' + (data.error || 'unknown'));
        }"""

new_line_branch = """      if (row.kind === 'unassigned_line' && lines) {
        const unassigned = lines.filter(l => !l.department);
        let success = 0;
        let lastError = '';
        for (const l of unassigned) {
          const assign = lineAssignments[l.line_id];
          if (!assign?.dept && !assign?.cat) continue;
          const res = await fetch('/app/api/feedback/line', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              line_id: l.line_id,
              corrected_department: assign.dept || null,
              corrected_category: assign.cat || null,
              corrected_by: 'jo',
            }),
          });
          const data = await res.json();
          if (data.ok) success++;
          else lastError = data.error || 'unknown';
        }
        if (lastError) setMessage(success > 0 ? `${success} assigned, errors: ${lastError}` : 'Error: ' + lastError);
        else setMessage(`${success} lines assigned! Refreshing...`);
        if (success > 0) setTimeout(onClose, 1200);"""

content = content.replace(old_line_branch, new_line_branch)

with open(path, "w") as f:
    f.write(content)

print("tasks/page.tsx updated")
