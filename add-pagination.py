#!/usr/bin/env python3
"""Add pagination to sales table and fix pollclock alignment."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

# === 1. Add page state after tableFilter ===
old_state = "const [tableFilter, setTableFilter] = useState<'' | 'high_labour' | 'low_sales' | 'has_data'>('has_data');"

new_state = """const [tableFilter, setTableFilter] = useState<'' | 'high_labour' | 'low_sales' | 'has_data'>('has_data');
  const [page, setPage] = useState(0);
  const PER_PAGE = 10;"""

content = content.replace(old_state, new_state)

# === 2. Add pagination logic after footer ===
old_footer_end = """  }, [tableRows]);"""

new_footer_end = """  }, [tableRows]);

  // Paginated rows
  const totalPages = Math.max(1, Math.ceil(tableRows.length / PER_PAGE));
  const safePage = Math.min(page, totalPages - 1);
  const visibleRows = tableRows.slice(safePage * PER_PAGE, (safePage + 1) * PER_PAGE);"""

content = content.replace(old_footer_end, new_footer_end)

# === 3. Replace tableRows.map with visibleRows.map ===
content = content.replace(
    "                {tableRows.map((r) => (",
    "                {visibleRows.map((r) => ("
)

# === 4. Add pagination controls after table close ===
old_table_close = """          </div>
          <p className="mt-2 text-sm text-ink-500">"""

new_table_close = """          </div>
          {tableRows.length > PER_PAGE && (
            <div className="flex items-center justify-between mt-2 text-xs text-ink-500">
              <span>Showing {safePage * PER_PAGE + 1}–{Math.min((safePage + 1) * PER_PAGE, tableRows.length)} of {tableRows.length} days</span>
              <div className="flex items-center gap-1">
                <button onClick={() => setPage(Math.max(0, safePage - 1))}
                  disabled={safePage === 0}
                  className={'px-2 py-1 rounded ' + (safePage === 0 ? 'text-ink-400 cursor-default' : 'text-ink-200 hover:bg-ink-200 cursor-pointer')}>
                  ← Prev
                </button>
                {Array.from({ length: totalPages }, (_, i) => (
                  <button key={i} onClick={() => setPage(i)}
                    className={'px-2 py-1 rounded ' + (i === safePage ? 'bg-amber-500 text-ink-0' : 'text-ink-400 hover:text-ink-200 cursor-pointer')}>
                    {i + 1}
                  </button>
                ))}
                <button onClick={() => setPage(Math.min(totalPages - 1, safePage + 1))}
                  disabled={safePage >= totalPages - 1}
                  className={'px-2 py-1 rounded ' + (safePage >= totalPages - 1 ? 'text-ink-400 cursor-default' : 'text-ink-200 hover:bg-ink-200 cursor-pointer')}>
                  Next →
                </button>
              </div>
            </div>
          )}
          <p className="mt-2 text-sm text-ink-500">"""

content = content.replace(old_table_close, new_table_close)

with open(path, "w") as f:
    f.write(content)

print("Patched OK")
