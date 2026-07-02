#!/usr/bin/env python3
"""Add sortable column headers + keyword filter to flagged email table."""

path = "/home_ai/services/homeai-frontend/app/comms/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add sort + filter state
old_state_end = """  const [selectedTask, setSelectedTask] = useState<any>(null);
  const [actingTask, setActingTask] = useState<number | null>(null);"""

new_state_end = """  const [selectedTask, setSelectedTask] = useState<any>(null);
  const [actingTask, setActingTask] = useState<number | null>(null);
  const [sortCol, setSortCol] = useState('priority_score');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [flagFilter, setFlagFilter] = useState('all');
  const [searchText, setSearchText] = useState('');

  const toggleSort = (col: string) => {
    if (sortCol === col) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortCol(col); setSortDir('asc'); }
  };

  const sortIcon = (col: string) => {
    if (sortCol !== col) return '';
    return sortDir === 'asc' ? ' \\u2191' : ' \\u2193';
  };

  // Unique flags for filter
  const uniqueFlags = [...new Set((flagged.data ?? []).map((e: any) => e.matched_keyword))].sort();

  // Filtered + sorted data
  const emailRows = (flagged.data ?? [])
    .filter((e: any) => flagFilter === 'all' || e.matched_keyword === flagFilter)
    .filter((e: any) => !searchText || e.subject.toLowerCase().includes(searchText.toLowerCase()) || e.from_address.toLowerCase().includes(searchText.toLowerCase()))
    .sort((a: any, b: any) => {
      let cmp = 0;
      if (sortCol === 'priority_score') cmp = (a.priority_score || 0) - (b.priority_score || 0);
      else if (sortCol === 'severity') cmp = (a.severity || 0) - (b.severity || 0);
      else if (sortCol === 'matched_keyword') cmp = (a.matched_keyword || '').localeCompare(b.matched_keyword || '');
      else if (sortCol === 'subject') cmp = (a.subject || '').localeCompare(b.subject || '');
      else if (sortCol === 'from_address') cmp = (a.from_address || '').localeCompare(b.from_address || '');
      else if (sortCol === 'detected_at') cmp = new Date(a.detected_at).getTime() - new Date(b.detected_at).getTime();
      return sortDir === 'asc' ? cmp : -cmp;
    });"""

content = content.replace(old_state_end, new_state_end)

# 2. Replace the flagged table header and body
old_table = """              <table className=\"w-full text-xs\">
                <thead className=\"text-ink-500 uppercase tracking-wider\">
                  <tr>
                    <th className=\"text-left py-1.5\">Flag</th>
                    <th className=\"text-left\">Subject</th>
                    <th className=\"text-left\">From</th>
                    <th className=\"text-right\">Sev</th>
                    <th className=\"text-right\">Score</th>
                    <th className=\"text-right\">Date</th>
                  </tr>
                </thead>
                <tbody>
                  {(flagged.data ?? []).map((e: any) => ("""

new_table = """              <div className=\"mb-2 flex items-center gap-2 text-xs\">
                <span className=\"text-ink-500\">Flag:</span>
                <select value={flagFilter} onChange={(e) => setFlagFilter(e.target.value)}
                  className=\"bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1\">
                  <option value=\"all\">All</option>
                  {uniqueFlags.map(f => <option key={f} value={f}>{f}</option>)}
                </select>
                <input value={searchText} onChange={(e) => setSearchText(e.target.value)}
                  placeholder=\"Search subject or sender...\"
                  className=\"bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1 flex-1 max-w-64\" />
                <span className=\"text-ink-500\">{emailRows.length} of {flagged.data?.length || 0}</span>
              </div>
              <table className=\"w-full text-xs\">
                <thead className=\"text-ink-500 uppercase tracking-wider\">
                  <tr>
                    <th className=\"text-left py-1.5 cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('matched_keyword')}>Flag{sortIcon('matched_keyword')}</th>
                    <th className=\"text-left cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('subject')}>Subject{sortIcon('subject')}</th>
                    <th className=\"text-left cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('from_address')}>From{sortIcon('from_address')}</th>
                    <th className=\"text-right cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('severity')}>Sev{sortIcon('severity')}</th>
                    <th className=\"text-right cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('priority_score')}>Score{sortIcon('priority_score')}</th>
                    <th className=\"text-right cursor-pointer hover:text-ink-200\" onClick={() => toggleSort('detected_at')}>Date{sortIcon('detected_at')}</th>
                  </tr>
                </thead>
                <tbody>
                  {emailRows.length === 0 ? (
                    <tr><td colSpan={6} className=\"py-4 text-center text-ink-500\">No emails match the filter.</td></tr>
                  ) : (emailRows).map((e: any) => ("""

content = content.replace(old_table, new_table)

with open(path, "w") as f:
    f.write(content)

print("Done")
