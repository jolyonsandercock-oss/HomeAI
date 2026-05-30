#!/usr/bin/env python3
"""Add editable Business area dropdown to modal."""

path = "/home_ai/services/homeai-frontend/app/tasks/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add site state
content = content.replace(
    "const [category, setCategory] = useState('');",
    "const [category, setCategory] = useState('');\n  const [site, setSite] = useState('');"
)

# 2. Remove static info line
content = content.replace(
    '          <p><span className="text-ink-500">Business area:</span> {row.site || \'shared\'}</p>\n        </div>',
    "        </div>"
)

# 3. Add Business area dropdown before Department
content = content.replace(
    '        <div className="space-y-3">\n          <div>\n            <label className="block text-xs text-ink-500 mb-1">Department</label>',
    '''        <div className="space-y-3">
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
            <label className="block text-xs text-ink-500 mb-1">Department</label>'''
)

with open(path, "w") as f:
    f.write(content)

print("Done")
