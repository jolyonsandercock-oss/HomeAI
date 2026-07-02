#!/usr/bin/env python3
"""Add force-extract button to invoice detail page."""

path = "/home_ai/services/homeai-frontend/app/admin/invoices/[id]/page.tsx"

with open(path) as f:
    content = f.read()

# The button block ends with the Open PDF and build-dashboard links
# Find "Open in build-dashboard </a>"
old_close = "Open in build-dashboard <ExternalLink size={12} />\n                </a>\n              </div>"

new_close = """Open in build-dashboard <ExternalLink size={12} />
                </a>
                {(h.has_pdf && (lines.data?.length ?? 0) === 0) && (
                  <button
                    onClick={async () => {
                      setForceExtracting(true);
                      setForceExtractMsg('');
                      try {
                        const res = await fetch('/app/api/extract/invoice', {
                          method: 'POST',
                          headers: { 'Content-Type': 'application/json' },
                          body: JSON.stringify({ invoice_id: h.id }),
                        });
                        const data = await res.json();
                        if (data.ok) {
                          setForceExtractMsg('Queued for re-extraction');
                        } else {
                          setForceExtractMsg('Error: ' + (data.error || ''));
                        }
                      } catch (e: any) {
                        setForceExtractMsg('Error: ' + e.message);
                      }
                      setForceExtracting(false);
                    }}
                    disabled={forceExtracting}
                    className="text-xs px-2.5 py-1.5 rounded-md inline-flex items-center gap-1 bg-amber-900/30 hover:bg-amber-900/50 text-amber-300 disabled:opacity-50">
                    <RefreshCcw size={12} className={forceExtracting ? 'animate-spin' : ''} />
                    {forceExtracting ? 'Queuing...' : 'Re-extract lines'}
                  </button>
                )}
                {forceExtractMsg && (
                  <span className="text-xs text-ink-500 ml-2">{forceExtractMsg}</span>
                )}
              </div>"""

content = content.replace(old_close, new_close)

with open(path, "w") as f:
    f.write(content)

print("Done" if "Re-extract lines" in content else "Button not found - may need different pattern")
