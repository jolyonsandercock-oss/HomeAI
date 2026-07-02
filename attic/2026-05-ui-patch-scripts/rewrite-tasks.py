#!/usr/bin/env python3
"""Rewrite tasks page — 30d filterable/sortable action queue + expense exceptions."""

path = "/home_ai/services/homeai-frontend/app/tasks/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add useState for filters and sorting
old_imports = """import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { KPICard } from '@/components/ui/KPICard';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';"""

new_imports = """import { useMemo, useState } from 'react';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { KPICard } from '@/components/ui/KPICard';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';"""

content = content.replace(old_imports, new_imports)

# 2. Add filter state + filtered/sorted data after counts
old_after_counts = """  return (
    <div className=\"space-y-6\">
      <SandboxWrapper id=\"tasks.summary\">
        <Section title=\"Action queue — summary\">"""

new_after_counts = """  // Filter & sort state
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
    <div className=\"space-y-6\">
      <SandboxWrapper id=\"tasks.summary\">
        <Section title=\"Action queue — summary\">"""

content = content.replace(old_after_counts, new_after_counts)

# 3. Update KPI counts to use filtered data
content = content.replace(
  "const counts = (q.data || []).reduce((acc, r) => {",
  "const thirtyDaysAgo = new Date(); thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);\n  const recentData = (q.data || []).filter(r => new Date(r.age_date) >= thirtyDaysAgo);\n  const counts = recentData.reduce((acc, r) => {"
)

# 4. Replace the queue table with filterable/sortable version
old_table = """          ) : q.data && q.data.length > 0 ? (
            <div className=\"tile overflow-x-auto\">
              <table className=\"w-full text-sm\">
                <thead className=\"text-xs text-ink-500 uppercase tracking-wider\">
                  <tr>
                    <th className=\"text-left py-2 font-medium\">Severity</th>
                    <th className=\"text-left font-medium\">Kind</th>
                    <th className=\"text-left font-medium\">Title</th>
                    <th className=\"text-right font-medium\">Age</th>
                  </tr>
                </thead>
                <tbody>
                  {q.data.map((r) => (
                    <tr key={`${r.source}-${r.ref}`} className=\"border-t border-ink-200\">
                      <td className={'py-1.5 font-mono text-xs ' + (severityColour[r.severity ?? 'low'])}>
                        {r.severity ?? '—'}
                      </td>
                      <td className=\"text-xs text-ink-500\">{r.kind}</td>
                      <td className=\"text-ink-800\">{r.title}</td>
                      <td className=\"text-right font-mono text-xs text-ink-500\">{r.age_days}d</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <PlaceholderState message=\"No open actions.\" />
          )}"""

new_table = """          ) : (
            <>
              <div className=\"mb-2 flex items-center gap-2 text-xs\">
                <span className=\"text-ink-500\">Severity:</span>
                <select value={filterSeverity} onChange={(e) => setFilterSeverity(e.target.value)}
                  className=\"bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1\">
                  <option value=\"all\">All</option>
                  <option value=\"critical\">Critical</option>
                  <option value=\"high\">High</option>
                  <option value=\"medium\">Medium</option>
                  <option value=\"low\">Low</option>
                </select>
                <span className=\"text-ink-400\">|</span>
                <span className=\"text-ink-500\">{filtered.length} items (last 30d)</span>
              </div>
              {filtered.length > 0 ? (
              <div className=\"tile overflow-x-auto\">
                <table className=\"w-full text-sm\">
                  <thead className=\"text-xs text-ink-500 uppercase tracking-wider\">
                    <tr>
                      <th className=\"text-left py-2 font-medium cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('severity')}>
                        Severity{sortIcon('severity')}
                      </th>
                      <th className=\"text-left font-medium cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('kind')}>
                        Kind{sortIcon('kind')}
                      </th>
                      <th className=\"text-left font-medium cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('title')}>
                        Title{sortIcon('title')}
                      </th>
                      <th className=\"text-right font-medium cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('age_days')}>
                        Age{sortIcon('age_days')}
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {filtered.map((r) => (
                      <tr key={`${r.source}-${r.ref}`} className=\"border-t border-ink-200\">
                        <td className={'py-1.5 font-mono text-xs ' + (severityColour[r.severity ?? 'low'])}>
                          {r.severity ?? '—'}
                        </td>
                        <td className=\"text-xs text-ink-500\">{r.kind}</td>
                        <td className=\"text-ink-800\">{r.title}</td>
                        <td className=\"text-right font-mono text-xs text-ink-500\">{r.age_days}d</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              ) : (
                <PlaceholderState message=\"No actions match the filter.\" />
              )}
            </>
          )}"""

content = content.replace(old_table, new_table)

with open(path, "w") as f:
    f.write(content)

print("tasks/page.tsx updated")
