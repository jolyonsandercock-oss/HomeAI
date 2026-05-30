#!/usr/bin/env python3
"""Add clickable row modal for assigning categories on expense exceptions."""

path = "/home_ai/services/homeai-frontend/app/tasks/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add line_id to the interface
content = content.replace(
    "interface ExpenseExceptionRow {\n  kind: string;\n  vendor_domain: string;\n  vendor_display: string;\n  invoice_count: number;\n  total_gross: string;\n  last_seen: string;\n  detail: string;\n}",
    "interface ExpenseExceptionRow {\n  kind: string;\n  line_id: number | null;\n  vendor_domain: string;\n  vendor_display: string;\n  invoice_count: number;\n  total_gross: string;\n  last_seen: string;\n  detail: string;\n}"
)

# 2. Add modal component + state before ExpenseExceptionSection
old_func_start = "function ExpenseExceptionSection() {"
new_func_start = """function AssignModal({ row, onClose }: { row: ExpenseExceptionRow | null; onClose: () => void }) {
  const [dept, setDept] = useState('');
  const [category, setCategory] = useState('');
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState('');

  if (!row) return null;

  const handleAssign = async () => {
    if (!dept && !category) { setMessage('Select at least one'); return; }
    setSaving(true);
    setMessage('');
    try {
      if (row.kind === 'unassigned_line' && row.line_id) {
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
        }
      } else if (row.kind === 'uncategorised_vendor') {
        setMessage('Vendor rules are set via auto-classify cron. Direct assignment coming soon.');
        setTimeout(onClose, 2000);
      }
    } catch (e: any) {
      setMessage('Error: ' + (e.message || 'network error'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60" onClick={onClose}>
      <div className="bg-ink-50 border border-ink-200 rounded-lg w-full max-w-md p-5 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-sm font-medium text-ink-800">Assign {row.kind === 'unassigned_line' ? 'line item' : 'vendor'}</h3>
          <button onClick={onClose} className="text-ink-400 hover:text-ink-600 text-lg leading-none">&times;</button>
        </div>
        <div className="space-y-2 text-xs text-ink-600 mb-4">
          <p><span className="text-ink-500">Vendor:</span> {row.vendor_display}</p>
          <p><span className="text-ink-500">Detail:</span> {row.detail}</p>
          <p><span className="text-ink-500">Amount:</span> {gbp(parseFloat(row.total_gross))}</p>
        </div>
        <div className="space-y-3">
          <div>
            <label className="block text-xs text-ink-500 mb-1">Department</label>
            <select value={dept} onChange={(e) => setDept(e.target.value)}
              className="w-full bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 text-xs">
              <option value=""> unchanged</option>
              <option value="bar">Bar</option>
              <option value="kitchen">Kitchen</option>
              <option value="rooms">Rooms</option>
              <option value="cafe">Cafe</option>
              <option value="overhead">Overhead</option>
            </select>
          </div>
          <div>
            <label className="block text-xs text-ink-500 mb-1">Category</label>
            <select value={category} onChange={(e) => setCategory(e.target.value)}
              className="w-full bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 text-xs">
              <option value=""> unchanged</option>
              <option value="Beverage">Beverage</option>
              <option value="Bookings">Bookings</option>
              <option value="Food">Food</option>
              <option value="Laundry">Laundry</option>
              <option value="Maintenance">Maintenance</option>
              <option value="Software">Software</option>
              <option value="Other">Other</option>
            </select>
          </div>
        </div>
        {message && (
          <div className={'mt-3 text-xs ' + (message.startsWith('Error') ? 'text-warn' : 'text-green-400')}>{message}</div>
        )}
        <div className="mt-4 flex justify-end gap-2">
          <button onClick={onClose} className="px-3 py-1.5 text-xs rounded bg-ink-200 text-ink-600 hover:bg-ink-300">Cancel</button>
          <button onClick={handleAssign} disabled={saving}
            className="px-3 py-1.5 text-xs rounded bg-amber-500 text-ink-0 hover:bg-amber-400 disabled:opacity-50">
            {saving ? 'Saving...' : 'Assign'}
          </button>
        </div>
      </div>
    </div>
  );
}

function ExpenseExceptionSection() {
  const [selectedRow, setSelectedRow] = useState<ExpenseExceptionRow | null>(null);"""

content = content.replace(old_func_start, new_func_start)

# 3. Make rows clickable - replace the tr tags
content = content.replace(
    '<tr key={r.vendor_domain + r.detail} className="border-t border-ink-200">',
    '<tr key={r.vendor_domain + r.detail} className="border-t border-ink-200 cursor-pointer hover:bg-ink-100/50" onClick={() => setSelectedRow(r)}>'
)

old_tr2 = '<tr key={r.vendor_domain + r.detail + i} className="border-t border-ink-200">'
new_tr2 = '<tr key={r.vendor_domain + r.detail + i} className="border-t border-ink-200 cursor-pointer hover:bg-ink-100/50" onClick={() => setSelectedRow(r)}>'
content = content.replace(old_tr2, new_tr2)

# 4. Add modal at end of section
old_end = """      )}
    </div>
  );
}"""

content = content.replace(
    old_end,
    """      )}
      {selectedRow && <AssignModal row={selectedRow} onClose={() => setSelectedRow(null)} />}
    </div>
  );
}"""
)

with open(path, "w") as f:
    f.write(content)

print("tasks/page.tsx updated")
