#!/usr/bin/env python3
"""Add sortable/filterable headers to the flagged email table on comms page."""

path = "/home_ai/services/homeai-frontend/app/comms/page.tsx"

with open(path) as f:
    content = f.read()

# Add email sort/filter state after the reviews sort state
old = """  const [searchText, setSearchText] = useState<string>('');
  const [sourceFilter, setSourceFilter] = useState<'all' | 'google' | 'tripadvisor' | 'booking_com'>('all');"""

new = """  const [searchText, setSearchText] = useState<string>('');
  const [sourceFilter, setSourceFilter] = useState<'all' | 'google' | 'tripadvisor' | 'booking_com'>('all');
  const [emailSortCol, setEmailSortCol] = useState('priority_score');
  const [emailSortDir, setEmailSortDir] = useState<'asc' | 'desc'>('desc');
  const [emailFlagFilter, setEmailFlagFilter] = useState('all');
  const [emailSearch, setEmailSearch] = useState('');

  const emailSortIcon = (col: string) => {
    if (emailSortCol !== col) return '';
    return emailSortDir === 'asc' ? ' \\u2191' : ' \\u2193';
  };
  const emailToggleSort = (col: string) => {
    if (emailSortCol === col) setEmailSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setEmailSortCol(col); setEmailSortDir('asc'); }
  };
  const emailFlags = [...new Set((flagged.data ?? []).map((e: any) => e.matched_keyword))].sort();
  const emailRows = (flagged.data ?? [])
    .filter((e: any) => emailFlagFilter === 'all' || e.matched_keyword === emailFlagFilter)
    .filter((e: any) => !emailSearch || e.subject.toLowerCase().includes(emailSearch.toLowerCase()) || e.from_address.toLowerCase().includes(emailSearch.toLowerCase()))
    .sort((a: any, b: any) => {
      let cmp = 0;
      if (emailSortCol === 'priority_score') cmp = (a.priority_score || 0) - (b.priority_score || 0);
      else if (emailSortCol === 'severity') cmp = (a.severity || 0) - (b.severity || 0);
      else if (emailSortCol === 'matched_keyword') cmp = (a.matched_keyword || '').localeCompare(b.matched_keyword || '');
      else if (emailSortCol === 'subject') cmp = (a.subject || '').localeCompare(b.subject || '');
      else if (emailSortCol === 'from_address') cmp = (a.from_address || '').localeCompare(b.from_address || '');
      else if (emailSortCol === 'detected_at') cmp = new Date(a.detected_at).getTime() - new Date(b.detected_at).getTime();
      return emailSortDir === 'asc' ? cmp : -cmp;
    });"""

content = content.replace(old, new)

# Replace the flagged table header
old_thead = """              <table className=\"w-full text-xs\">
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

new_thead = """              <div className=\"mb-2 flex items-center gap-2 text-xs\">
                <span className=\"text-ink-500\">Flag:</span>
                <select value={emailFlagFilter} onChange={(e) => setEmailFlagFilter(e.target.value)}
                  className=\"bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1\">
                  <option value=\"all\">All</option>
                  {emailFlags.map(f => <option key={f} value={f}>{f}</option>)}
                </select>
                <input value={emailSearch} onChange={(e) => setEmailSearch(e.target.value)}
                  placeholder=\"Search...\"
                  className=\"bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1 flex-1 max-w-48\" />
                <span className=\"text-ink-500\">{emailRows.length} of {flagged.data?.length || 0}</span>
              </div>
              <table className=\"w-full text-xs\">
                <thead className=\"text-ink-500 uppercase tracking-wider\">
                  <tr>
                    <th className=\"text-left py-1.5 cursor-pointer hover:text-ink-200\" onClick={() => emailToggleSort('matched_keyword')}>Flag{emailSortIcon('matched_keyword')}</th>
                    <th className=\"text-left cursor-pointer hover:text-ink-200\" onClick={() => emailToggleSort('subject')}>Subject{emailSortIcon('subject')}</th>
                    <th className=\"text-left cursor-pointer hover:text-ink-200\" onClick={() => emailToggleSort('from_address')}>From{emailSortIcon('from_address')}</th>
                    <th className=\"text-right cursor-pointer hover:text-ink-200\" onClick={() => emailToggleSort('severity')}>Sev{emailSortIcon('severity')}</th>
                    <th className=\"text-right cursor-pointer hover:text-ink-200\" onClick={() => emailToggleSort('priority_score')}>Score{emailSortIcon('priority_score')}</th>
                    <th className=\"text-right cursor-pointer hover:text-ink-200\" onClick={() => emailToggleSort('detected_at')}>Date{emailSortIcon('detected_at')}</th>
                  </tr>
                </thead>
                <tbody>
                  {emailRows.length === 0 ? (
                    <tr><td colSpan={6} className=\"py-4 text-center text-ink-500\">No emails match filters.</td></tr>
                  ) : (emailRows).map((e: any) => ("""

content = content.replace(old_thead, new_thead)

with open(path, "w") as f:
    f.write(content)

print("Done")
