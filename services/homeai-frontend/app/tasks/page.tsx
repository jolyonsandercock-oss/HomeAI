'use client';

import { useMemo, useState, useEffect } from 'react';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { KPICard } from '@/components/ui/KPICard';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';

interface ActionRow {
  source: string;
  ref: string;
  severity: 'critical' | 'high' | 'medium' | 'low' | null;
  kind: string;
  title: string;
  age_date: string;
  age_days: number;
  realm: string;
}

interface LineDetail {
  line_id: number;
  invoice_id: number;
  description: string;
  line_gross: string;
  department: string | null;
  extracted_by: string | null;
  subject: string;
  received_at: string;
  has_pdf_text: boolean;
}

interface SnagRow { id: number; title: string; description: string | null; image_path: string | null; category: string; priority: number; status: string; source: string; submitted_by: string | null; created_at: string }

interface ExpenseExceptionRow {
  kind: string;
  line_id: number | null;
  vendor_domain: string;
  vendor_display: string;
  invoice_count: number;
  total_gross: string;
  last_seen: string;
  detail: string;
  site: string;
}

const severityColour: Record<string, string> = {
  critical: 'text-warn font-bold',
  high:     'text-warn',
  medium:   'text-amber-500',
  low:      'text-ink-500',
};

export default function TasksPage() {
  const q = useSlug<ActionRow>('frontend_action_queue', {}, { refetchInterval: 60_000 });

  const thirtyDaysAgo = new Date(); thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
  const recentData = (q.data || []).filter(r => new Date(r.age_date) >= thirtyDaysAgo);
  const counts = recentData.reduce((acc, r) => {
    const s = r.severity ?? 'unknown';
    acc[s] = (acc[s] || 0) + 1;
    return acc;
  }, {} as Record<string, number>);

  // Filter & sort state
  const [filterSeverity, setFilterSeverity] = useState<string>('all');
  const [sortCol, setSortCol] = useState<string>('age_days');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');

  // Apply 30d cut-off, filter, and sort
  const filtered = useMemo(() => {
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
    
    let rows = (q.data ?? []).filter(r => {
      // 30d filter
      const age = new Date(r.age_date);
      if (age < thirtyDaysAgo) return false;
      // Severity filter
      if (filterSeverity !== 'all' && r.severity !== filterSeverity) return false;
      return true;
    });

    // Sort
    rows.sort((a, b) => {
      let cmp = 0;
      if (sortCol === 'age_days') cmp = a.age_days - b.age_days;
      else if (sortCol === 'severity') {
        const order = { critical: 0, high: 1, medium: 2, low: 3 };
        cmp = (order[a.severity ?? 'low'] ?? 4) - (order[b.severity ?? 'low'] ?? 4);
      }
      else if (sortCol === 'kind') cmp = a.kind.localeCompare(b.kind);
      else if (sortCol === 'title') cmp = a.title.localeCompare(b.title);
      return sortDir === 'asc' ? cmp : -cmp;
    });

    return rows;
  }, [q.data, filterSeverity, sortCol, sortDir]);

  const toggleSort = (col: string) => {
    if (sortCol === col) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortCol(col); setSortDir('asc'); }
  };

  const sortIcon = (col: string) => {
    if (sortCol !== col) return ' ↕';
    return sortDir === 'asc' ? ' ↑' : ' ↓';
  };

  return (
    <div className="space-y-6">
      <SandboxWrapper id="tasks.summary">
        <Section title="Action queue — summary">
          <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
            <KPICard label="Total" value={q.data?.length ?? '—'} size="xl" loading={q.isLoading} />
            <KPICard label="Critical" value={counts.critical ?? 0} />
            <KPICard label="High" value={counts.high ?? 0} />
            <KPICard label="Medium" value={counts.medium ?? 0} />
            <KPICard label="Low" value={counts.low ?? 0} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="tasks.queue" label="Action queue">
        <Section title="Open actions">
          {q.isLoading ? (
            <PlaceholderState message="Loading action queue…" />
          ) : (
            <>
              <div className="mb-2 flex items-center gap-2 text-xs">
                <span className="text-ink-500">Severity:</span>
                <select value={filterSeverity} onChange={(e) => setFilterSeverity(e.target.value)}
                  className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1">
                  <option value="all">All</option>
                  <option value="critical">Critical</option>
                  <option value="high">High</option>
                  <option value="medium">Medium</option>
                  <option value="low">Low</option>
                </select>
                <span className="text-ink-400">|</span>
                <span className="text-ink-500">{filtered.length} items (last 30d)</span>
              </div>
              {filtered.length > 0 ? (
              <div className="tile overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="text-xs text-ink-500 uppercase tracking-wider">
                    <tr>
                      <th className="text-left py-2 font-medium cursor-pointer hover:text-ink-200" onClick={() => toggleSort('severity')}>
                        Severity{sortIcon('severity')}
                      </th>
                      <th className="text-left font-medium cursor-pointer hover:text-ink-200" onClick={() => toggleSort('kind')}>
                        Kind{sortIcon('kind')}
                      </th>
                      <th className="text-left font-medium cursor-pointer hover:text-ink-200" onClick={() => toggleSort('title')}>
                        Title{sortIcon('title')}
                      </th>
                      <th className="text-right font-medium cursor-pointer hover:text-ink-200" onClick={() => toggleSort('age_days')}>
                        Age{sortIcon('age_days')}
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {filtered.map((r) => (
                      <tr key={`${r.source}-${r.ref}`} className="border-t border-ink-200">
                        <td className={'py-1.5 font-mono text-xs ' + (severityColour[r.severity ?? 'low'])}>
                          {r.severity ?? '—'}
                        </td>
                        <td className="text-xs text-ink-500">{r.kind}</td>
                        <td className="text-ink-800">{r.title}</td>
                        <td className="text-right font-mono text-xs text-ink-500">{r.age_days}d</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              ) : (
                <PlaceholderState message="No actions match the filter." />
              )}
            </>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="tasks.expense-exceptions" label="Expense exceptions">
        <ExpenseExceptionSection />
      </SandboxWrapper>
    </div>
  );
}

function AssignModal({ row, onClose }: { row: ExpenseExceptionRow | null; onClose: () => void }) {
  const [dept, setDept] = useState('');
  const [category, setCategory] = useState('');
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
  }, [row]);

  if (!row) return null;

  const handleAssign = async () => {
    setSaving(true);
    setMessage('');
    try {
      if (row.kind === 'unassigned_line' && lines) {
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
        if (success > 0) setTimeout(onClose, 1200);
      } else if (row.kind === 'uncategorised_vendor') {
        // Create vendor_category_rules entry directly via slug API
        const domainPart = row.vendor_domain.split('@').pop() || row.vendor_domain;
        const cleanDomain = domainPart.replace(/^www\./, '');
        const res = await fetch('/app/api/categorise/vendor', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            domain_pattern: cleanDomain,
            category: category || null,
            site: site || row.site || 'shared',
            vendor_display: row.vendor_display,
          }),
        });
        const data = await res.json();
        if (data.ok) {
          setMessage('Rule created! Refreshing...');
          setTimeout(onClose, 1200);
        } else {
          setMessage('Error: ' + (data.error || 'unknown'));
        }
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
          {row.kind === 'unassigned_line' && lines ? (
            <p><span className="text-ink-500">Lines:</span> {lines.length} line items from this vendor</p>
          ) : (
            <>
              <p><span className="text-ink-500">Detail:</span> {row.detail}</p>
              <p><span className="text-ink-500">Amount:</span> {gbp(parseFloat(row.total_gross))}</p>
            </>
          )}
        </div>
        {row.kind === 'unassigned_line' && lines ? (
          /* Line-by-line view */
          <div className="space-y-2 max-h-80 overflow-y-auto">
            <div className="text-xs text-ink-500 mb-1 font-medium">Line items from {row.vendor_display}</div>
            {loadingLines ? (
              <div className="text-xs text-ink-500">Loading lines...</div>
            ) : (
              <table className="w-full text-xs font-mono">
                <thead className="text-ink-500 uppercase tracking-wider text-2xs">
                  <tr>
                    <th className="text-left py-1">Description</th>
                    <th className="text-right py-1">Amount</th>
                    <th className="text-right py-1">Dept</th>
                  </tr>
                </thead>
                <tbody>
                  {lines.filter(l => !l.department).map(l => (
                    <tr key={l.line_id} className="border-t border-ink-200">
                      <td className="py-1 pr-2 text-ink-800 max-w-[200px] truncate" title={l.description}>{l.description}</td>
                      <td className="py-1 text-right text-ink-500">{gbp(parseFloat(l.line_gross))}</td>
                      <td className="py-1">
                        <select value={lineAssignments[l.line_id]?.dept || ''} 
                          onChange={(e) => setLineAssignments(prev => ({ ...prev, [l.line_id]: { ...prev[l.line_id], dept: e.target.value, cat: prev[l.line_id]?.cat || '' } }))}
                          className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-1 py-0.5 text-2xs w-20">
                          <option value="">-</option>
                          <option value="bar">Bar</option>
                          <option value="kitchen">Kitchen</option>
                          <option value="rooms">Rooms</option>
                          <option value="cafe">Cafe</option>
                          <option value="overhead">Overhead</option>
                        </select>
                      </td>
                    </tr>
                  ))}
                  {lines.filter(l => !l.department).length === 0 && (
                    <tr><td colSpan={3} className="py-2 text-center text-ink-500">All lines assigned</td></tr>
                  )}
                </tbody>
              </table>
            )}
          </div>
        ) : (
          /* Single-item view for vendors */
          <div className="space-y-3">
            <div>
              <label className="block text-xs text-ink-500 mb-1">Business area</label>
              <select value={site} onChange={(e) => setSite(e.target.value)}
                className="w-full bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 text-xs">
                <option value=""> unchanged</option>
                <option value="shared">Shared</option>
                <option value="pub">Pub</option>
                <option value="cafe">Cafe</option>
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
                <option value="Other">Other</option>
              </select>
            </div>
          </div>
        )}
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

function SnagInboxSection() {
  const [showForm, setShowForm] = useState(false);
  const snags = useSlug<SnagRow>('snag_inbox_pending', {}, { refetchInterval: 60_000 });
  const [actingId, setActingId] = useState<number | null>(null);

  const counts = { pending: (snags.data ?? []).filter(s => s.status === 'pending').length, accepted: (snags.data ?? []).filter(s => s.status === 'accepted').length, in_progress: (snags.data ?? []).filter(s => s.status === 'in_progress').length };

  const handleStatus = async (id: number, status: string) => {
    setActingId(id);
    try { await fetch('/app/api/snag/status', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, status }) }); } catch {}
    setActingId(null);
  };

  return (
    <>
      {/* Submission form */}
      <div className="mb-4 tile p-3">
        <div className="text-xs text-ink-500 uppercase mb-2">Submit new snag</div>
        <form onSubmit={async (e) => {
          e.preventDefault();
          const form = e.currentTarget;
          const fd = new FormData();
          fd.append('title', (form.querySelector('[name=title]') as HTMLInputElement).value);
          fd.append('description', (form.querySelector('[name=desc]') as HTMLTextAreaElement).value);
          fd.append('category', (form.querySelector('[name=category]') as HTMLSelectElement).value);
          fd.append('priority', (form.querySelector('[name=priority]') as HTMLSelectElement).value);
          const fileInput = form.querySelector('[name=image]') as HTMLInputElement;
          if (fileInput.files?.[0]) fd.append('image', fileInput.files[0]);
          try {
            const res = await fetch('/app/api/snag/upload', { method: 'POST', body: fd });
            if (!res.ok) throw new Error('Upload failed');
            (form as HTMLFormElement).reset();
            (form.querySelector('.preview-img') as HTMLElement).style.display = 'none';
            setShowForm(false);
            setTimeout(() => window.location.reload(), 500);
          } catch (err) { alert('Failed to submit. Try again.'); }
        }} className="space-y-2">
          <input name="title" placeholder="What's the issue?" required className="w-full bg-ink-50 border border-ink-200 rounded px-3 py-2 text-sm text-ink-900 placeholder:text-ink-400 focus:outline-none focus:border-amber-500" />
          <textarea name="desc" placeholder="Description (optional)" rows={2} className="w-full bg-ink-50 border border-ink-200 rounded px-3 py-2 text-sm text-ink-900 placeholder:text-ink-400 focus:outline-none focus:border-amber-500" />
          <div className="flex gap-2">
            <select name="category" defaultValue="improvement" className="bg-ink-50 border border-ink-200 rounded px-2 py-1.5 text-xs text-ink-700">
              <option value="improvement">Improvement</option>
              <option value="bug">Bug</option>
              <option value="complaint">Complaint</option>
              <option value="ux">UX feedback</option>
              <option value="other">Other</option>
            </select>
            <select name="priority" defaultValue="2" className="bg-ink-50 border border-ink-200 rounded px-2 py-1.5 text-xs text-ink-700">
              <option value="1">P1 — Urgent</option>
              <option value="2">P2 — Normal</option>
              <option value="3">P3 — Low</option>
            </select>
          </div>
          <div 
            className="border-2 border-dashed border-ink-300 rounded p-3 text-center cursor-pointer hover:border-amber-500 transition-colors"
            onDragOver={(e) => { e.preventDefault(); e.currentTarget.classList.add('border-amber-500'); }}
            onDragLeave={(e) => e.currentTarget.classList.remove('border-amber-500')}
            onDrop={(e) => {
              e.preventDefault();
              e.currentTarget.classList.remove('border-amber-500');
              const file = e.dataTransfer.files[0];
              if (file && file.type.startsWith('image/')) {
                const dt = new DataTransfer();
                dt.items.add(file);
                const input = e.currentTarget.querySelector('input[type=file]') as HTMLInputElement;
                input.files = dt.files;
                const preview = e.currentTarget.querySelector('.preview-img') as HTMLImageElement;
                preview.src = URL.createObjectURL(file);
                preview.style.display = 'block';
              }
            }}
            onClick={(e) => {
              const input = (e.currentTarget.querySelector('input[type=file]') as HTMLInputElement);
              if (e.target !== input) input.click();
            }}
          >
            <input 
              type="file" name="image" accept="image/*" className="hidden"
              onChange={(e) => {
                const file = e.currentTarget.files?.[0];
                if (file) {
                  const preview = e.currentTarget.parentElement?.querySelector('.preview-img') as HTMLImageElement;
                  if (preview) { preview.src = URL.createObjectURL(file); preview.style.display = 'block'; }
                }
              }}
            />
            <img className="preview-img hidden max-h-40 mx-auto mb-2 rounded" alt="Preview" />
            <div className="text-xs text-ink-400">Drop a screenshot here or click to upload</div>
          </div>
          <button type="submit" className="w-full bg-amber-500 text-ink-50 rounded px-3 py-2 text-sm font-medium hover:bg-amber-400 transition-colors">Submit snag</button>
        </form>
      </div>

      {snags.isLoading ? (
        <PlaceholderState message="Loading snag inbox\u2026" />
      ) : (snags.data ?? []).length === 0 ? (
        <PlaceholderState message="Snag inbox empty \— all clear!" />
      ) : (
        <>
          <div className="grid grid-cols-3 gap-2 mb-3 text-xs">
            <div className="bg-ink-100 rounded px-2 py-1 text-center"><span className="text-amber-400 font-bold">{counts.pending}</span> pending</div>
            <div className="bg-ink-100 rounded px-2 py-1 text-center"><span className="text-blue-400 font-bold">{counts.in_progress}</span> in progress</div>
            <div className="bg-ink-100 rounded px-2 py-1 text-center"><span className="text-ink-500 font-bold">{counts.accepted}</span> accepted</div>
          </div>
          <div className="tile overflow-x-auto text-xs">
            <table className="w-full">
              <thead className="text-ink-500 uppercase tracking-wider">
                <tr>
                  <th className="text-left py-1.5">P</th>
                  <th className="text-left">Title</th>
                  <th className="text-left">Category</th>
                  <th className="text-right">Source</th>
                  <th className="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                {(snags.data ?? []).map(s => (
                  <tr key={s.id} className="border-t border-ink-200">
                    <td className={'py-1.5 font-bold ' + (s.priority <= 2 ? 'text-red-400' : s.priority <= 3 ? 'text-amber-400' : 'text-ink-500')}>P{s.priority}</td>
                    <td className="text-ink-800 max-w-[300px] truncate" title={s.title}>{s.title}</td>
                    <td className="text-ink-500">{s.category}</td>
                    <td className="text-right text-ink-500">{s.source}</td>
                    <td className="text-right">
                      <div className="flex items-center justify-end gap-1">
                        <button onClick={() => handleStatus(s.id, 'accepted')} disabled={actingId === s.id || s.status !== 'pending'}
                          className="px-2 py-0.5 text-2xs rounded bg-blue-900/30 text-blue-400 hover:bg-blue-900/50 disabled:opacity-30">Accept</button>
                        <button onClick={() => handleStatus(s.id, 'done')} disabled={actingId === s.id}
                          className="px-2 py-0.5 text-2xs rounded bg-amber-500 text-ink-0 hover:bg-amber-400 disabled:opacity-30">Done</button>
                        <button onClick={() => handleStatus(s.id, 'wontfix')} disabled={actingId === s.id}
                          className="px-2 py-0.5 text-2xs rounded bg-red-900/30 text-red-400 hover:bg-red-900/50 disabled:opacity-30">Skip</button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}

function ExpenseExceptionSection() {
  const [selectedRow, setSelectedRow] = useState<ExpenseExceptionRow | null>(null);
  const [siteFilter, setSiteFilter] = useState('all');
  const exc = useSlug<ExpenseExceptionRow>('expense_tasks_exceptions', {}, { refetchInterval: 5 * 60_000 });
  const data = exc.data ?? [];
  
  const filtered = data.filter(d => siteFilter === 'all' || d.site === siteFilter);
  const uncatVendors = filtered.filter(d => d.kind === 'uncategorised_vendor');
  const unassignedLines = filtered.filter(d => d.kind === 'unassigned_line');
  const uncatGross = uncatVendors.reduce((a, r) => a + parseFloat(r.total_gross), 0);
  const unassignGross = unassignedLines.reduce((a, r) => a + parseFloat(r.total_gross), 0);
  const sites = [...new Set(data.map(d => d.site || 'shared'))].sort();

  return (
    <div className="space-y-4">
      {exc.isLoading ? (
        <PlaceholderState message="Loading expense exceptions…" />
      ) : data.length === 0 ? (
        <PlaceholderState message="No uncategorised vendors or unassigned line items." />
      ) : (
        <>
          <div className="mb-2 flex items-center gap-2 text-xs">
            <span className="text-ink-500">Business area:</span>
            <select value={siteFilter} onChange={(e) => setSiteFilter(e.target.value)}
              className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1">
              <option value="all">All</option>
              {sites.map(s => <option key={s} value={s}>{s}</option>)}
            </select>
            <span className="text-ink-400">|</span>
            <span className="text-ink-500">{filtered.length} items</span>
          </div>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <KPICard label="Uncat. vendors" value={uncatVendors.length} />
            <KPICard label="Uncat. £" value={gbp(uncatGross)} />
            <KPICard label="Unassigned lines" value={unassignedLines.length} />
            <KPICard label="Unassigned £" value={gbp(unassignGross)} />
          </div>

          {uncatVendors.length > 0 && (
            <Section title={`Uncategorised vendors (${uncatVendors.length}) — needs domain rule in vendor_category_rules`}>
              <div className="tile overflow-x-auto text-xs">
                <table className="w-full font-mono">
                  <thead className="text-ink-500 uppercase tracking-wider">
                    <tr>
                      <th className="text-left py-1.5">Vendor</th>
                      <th className="text-right">Invoices</th>
                      <th className="text-right">Total £</th>
                      <th className="text-right">Current cat.</th>
                      <th className="text-right">Last seen</th>
                    </tr>
                  </thead>
                  <tbody>
                    {uncatVendors.slice(0, 15).map(r => (
                      <tr key={r.vendor_domain + r.detail} className="border-t border-ink-200 cursor-pointer hover:bg-ink-100/50" onClick={() => setSelectedRow(r)}>
                        <td className="py-1.5 text-ink-900">
                          {r.vendor_display}
                          <a href={'https://mail.google.com/mail/u/0/#search/from%3A' + encodeURIComponent(r.vendor_domain)}
                             target="_blank" rel="noopener noreferrer"
                             className="ml-2 text-xs text-amber-500 hover:text-amber-400"
                             onClick={(e) => e.stopPropagation()}
                             title="Open in Gmail">&#x2197;</a>
                        </td>
                        <td className="text-right text-ink-500">{r.invoice_count}</td>
                        <td className="text-right text-warn">{gbp(parseFloat(r.total_gross))}</td>
                        <td className="text-right text-ink-500">{r.detail}</td>
                        <td className="text-right text-ink-500">{new Date(r.last_seen).toLocaleDateString('en-GB', {day:'numeric', month:'short'})}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </Section>
          )}

          {unassignedLines.length > 0 && (
            <Section title={`Unassigned line items (${unassignedLines.length}) — needs department assignment`}>
              <div className="tile overflow-x-auto text-xs">
                <table className="w-full font-mono">
                  <thead className="text-ink-500 uppercase tracking-wider">
                    <tr>
                      <th className="text-left py-1.5">Vendor</th>
                      <th className="text-left">Description</th>
                      <th className="text-right">Qty</th>
                      <th className="text-right">Total £</th>
                    </tr>
                  </thead>
                  <tbody>
                    {unassignedLines.slice(0, 20).map((r, i) => (
                      <tr key={r.vendor_domain + r.detail + i} className="border-t border-ink-200 cursor-pointer hover:bg-ink-100/50" onClick={() => setSelectedRow(r)}>
                        <td className="py-1.5 text-ink-700">{r.vendor_display.slice(0, 25)}</td>
                        <td className="text-ink-900">
                          {r.detail}
                          <a href={'https://mail.google.com/mail/u/0/#search/' + encodeURIComponent(r.detail.slice(0, 40))}
                             target="_blank" rel="noopener noreferrer"
                             className="ml-2 text-xs text-amber-500 hover:text-amber-400"
                             onClick={(e) => e.stopPropagation()}
                             title="Search in Gmail">&#x2197;</a>
                        </td>
                        <td className="text-right text-ink-500">{r.invoice_count}</td>
                        <td className="text-right text-amber-400">{gbp(parseFloat(r.total_gross))}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </Section>
          )}
        </>
      )}
      {selectedRow && <AssignModal row={selectedRow} onClose={() => setSelectedRow(null)} />}

      <SandboxWrapper id="tasks.snag-inbox" label="Snag inbox">
        <Section title={`Snag inbox \— improvements, complaints, UX feedback`}>
          <SnagInboxSection />
        </Section>
      </SandboxWrapper>
    </div>
  );
}
