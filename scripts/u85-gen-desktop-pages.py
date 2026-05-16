#!/usr/bin/env python3
"""u85-gen-desktop-pages.py — Generate every /desktop/* page from one config.

Saves us from copy-pasting 4kb of shared chrome 12 times. Pages are
re-generated whenever the section registry changes; commit the output.
"""
import pathlib, textwrap

STATIC = pathlib.Path('/home_ai/services/build-dashboard/static')

# ── Section registry ─────────────────────────────────────────────────────────
# code → (name, slug, render_kind, extra)
#
# render_kind = 'kpi4'    → 4-tile KPI strip (data.rows[0])
#              'table'   → generic table; auto-render all columns
#              'tableC'  → table with explicit column list (extra=cols)
#              'pills'   → pill list rendering for short categorical data
#              'note'    → static text only
SECTIONS = {
  # Today
  'T01': {'name': 'Today KPIs',          'slug': 'today_kpis_work',      'kind': 'kpi-today-work'},
  'T02': {'name': 'Private Today KPIs',  'slug': 'today_kpis_private',   'kind': 'kpi-today-private'},
  'T03': {'name': 'Today bookings',      'slug': 'today_bookings',       'kind': 't03-bookings'},
  'T04': {'name': 'Today pub sales',     'slug': 'today_pub_sales',      'kind': 't04-pub-sales'},
  # Actions
  'A01': {'name': 'Action queue',        'slug': 'action_queue',         'kind': 'a01-actions'},
  # Vendors / docs
  'V01': {'name': 'Top vendors',         'slug': 'top_vendors_window',   'kind': 'table'},
  'V02': {'name': 'Cost-centre split',   'slug': 'cost_centre_breakdown','kind': 'table'},
  'V03': {'name': 'Recent invoices',     'slug': 'recent_invoices',      'kind': 'table'},
  'V04': {'name': 'Spend by category',   'slug': 'spend_by_category_window','kind': 'table'},
  'V05': {'name': 'Vendor → site rules', 'slug': 'vendor_site_rules',    'kind': 'table'},
  'V06': {'name': 'Noise sender ignore', 'slug': 'noise_senders',        'kind': 'table'},
  # Cash / Finance
  'C01': {'name': 'Account balances',    'slug': 'account_balances',     'kind': 'table'},
  'C02': {'name': 'Credit cards',        'slug': 'credit_card_status',   'kind': 'table'},
  'C05': {'name': 'Inter-entity owings', 'slug': 'owings_summary',       'kind': 'table'},
  # Sales / EPOS
  'S01': {'name': 'Daily GP',            'slug': 'daily_gp_recent',      'kind': 'table'},
  # Labour / staff
  'L01': {'name': 'Labour by team · 14d','slug': 'labour_recent_14d',    'kind': 'table'},
  'L02': {'name': 'Ghost shifts',        'slug': 'ghost_shifts_recent',  'kind': 'table'},
  # Email
  'E01': {'name': 'Email tasks open',    'slug': 'email_tasks_open',     'kind': 'table'},
  'E02': {'name': 'Pending instructions','slug': 'bot_instructions_pending', 'kind': 'table'},
  # Docs / private
  'D01': {'name': 'Mortgages',           'slug': 'mortgages_all',        'kind': 'table'},
  'D02': {'name': 'Mortgage coverage',   'slug': 'mortgage_coverage',    'kind': 'table'},
  'D03': {'name': 'Vehicles',            'slug': 'private_vehicles',     'kind': 'table'},
  'D04': {'name': 'Children',            'slug': 'children',             'kind': 'table'},
  'D06': {'name': 'Net worth',           'slug': 'net_worth_summary',    'kind': 'table'},
  # Build
  'B01': {'name': 'AI pipeline status',  'slug': 'build_pipeline_status','kind': 'table'},
  'B02': {'name': 'Model spend 30d',     'slug': 'build_model_spend_30d','kind': 'table'},
  'B03': {'name': 'Forensic summary',    'slug': 'build_forensic_summary','kind': 'kpi4-forensic'},
  'B04': {'name': 'Page-view telemetry', 'slug': 'route_telemetry_7d',   'kind': 'table'},
  # Sitemap
  'R01': {'name': 'All sections registry','slug': None,                  'kind': 'r01-registry'},
}

# ── Page registry ────────────────────────────────────────────────────────────
PAGES = {
  # path → (bucket, page, pageName, [section codes in order])
  '/desktop/work/today':       ('work', 'today', 'Today',     ['T01', 'T03', 'T04', 'A01']),
  '/desktop/work/actions':     ('work', 'actions', 'Actions', ['A01']),
  '/desktop/work/docs':        ('work', 'docs', 'Docs',       ['V02', 'V03', 'V01', 'V04', 'V05', 'V06']),
  '/desktop/work/staff':       ('work', 'staff', 'Staff',     ['L01', 'L02']),
  '/desktop/work/email':       ('work', 'email', 'Email',     ['E01', 'E02']),
  '/desktop/work/finance':     ('work', 'finance', 'Finance', ['C01', 'C02', 'C05', 'S01']),
  '/desktop/private/today':    ('private', 'today', 'Today',  ['T02', 'D03', 'D01']),
  '/desktop/private/docs':     ('private', 'docs', 'Docs',    ['D01', 'D02', 'D03', 'D06']),
  '/desktop/private/family':   ('private', 'family', 'Family',['D04']),
  '/desktop/build/pipelines':  ('build', 'pipelines', 'Pipelines', ['B01']),
  '/desktop/build/models':     ('build', 'models', 'Models',  ['B02']),
  '/desktop/build/forensics':  ('build', 'forensics', 'Forensics', ['B03']),
  '/desktop/all':              ('all', 'sitemap', 'Sitemap',  ['R01']),
}


def page_filename(path: str) -> str:
    """`/desktop/work/today` → `desktop-work-today.html`."""
    return path.lstrip('/').replace('/', '-') + '.html'


def render_section(code: str) -> str:
    """Return the HTML for one section, including the §code header."""
    s = SECTIONS[code]
    name = s['name']
    slug = s['slug']
    kind = s['kind']
    slug_attr = f'slug: \'{slug}\'' if slug else ''

    if kind == 'kpi-today-work':
        body = '''
        <template x-if="loading"><div class="grid grid-cols-2 md:grid-cols-4 gap-2">
          <div class="skel h-20"></div><div class="skel h-20"></div>
          <div class="skel h-20"></div><div class="skel h-20"></div></div></template>
        <template x-if="!loading && data && data.rows && data.rows[0]">
          <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-slate-500">Cash on hand</div>
              <div class="text-2xl mono font-semibold mt-1" :class="data.rows[0].cash_on_hand >= 0 ? 'pos' : 'neg'">
                <span x-text="(data.rows[0].cash_on_hand >= 0 ? '£' : '-£') + Math.abs(+data.rows[0].cash_on_hand || 0).toLocaleString('en-GB', {maximumFractionDigits:0})"></span>
              </div>
            </div>
            <a href="/desktop/work/actions" class="bg-black/30 rounded-md p-3 hover:bg-black/40 block">
              <div class="text-xs uppercase tracking-wider text-slate-500">Open actions</div>
              <div class="text-2xl mono font-semibold mt-1">
                <span class="tl" :class="data.rows[0].critical_actions_count > 0 ? 'tl-red' : data.rows[0].open_actions_count > 50 ? 'tl-amber' : 'tl-green'"></span>
                <span x-text="data.rows[0].open_actions_count || 0"></span>
              </div>
            </a>
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-slate-500">Bookings tonight</div>
              <div class="text-2xl mono font-semibold mt-1">
                <span x-text="data.rows[0].bookings_today || 0"></span>
                <span class="text-sm text-slate-500">in</span>
              </div>
              <div class="text-xs text-slate-500 mt-1">£<span class="mono pos" x-text="(+data.rows[0].bookings_today_revenue || 0).toLocaleString('en-GB', {maximumFractionDigits:0})"></span></div>
            </div>
            <a href="/desktop/work/docs" class="bg-black/30 rounded-md p-3 hover:bg-black/40 block">
              <div class="text-xs uppercase tracking-wider text-slate-500">Docs expiring 30d</div>
              <div class="text-2xl mono font-semibold mt-1">
                <span class="tl" :class="data.rows[0].docs_expiring_30d > 0 ? 'tl-amber' : 'tl-green'"></span>
                <span x-text="data.rows[0].docs_expiring_30d || 0"></span>
              </div>
            </a>
          </div>
        </template>'''
    elif kind == 'kpi-today-private':
        body = '''
        <template x-if="loading"><div class="grid grid-cols-2 md:grid-cols-4 gap-2">
          <div class="skel h-20"></div><div class="skel h-20"></div>
          <div class="skel h-20"></div><div class="skel h-20"></div></div></template>
        <template x-if="!loading && data && data.rows && data.rows[0]">
          <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-slate-500">Family cash</div>
              <div class="text-2xl mono font-semibold mt-1" :class="data.rows[0].cash_on_hand >= 0 ? 'pos' : 'neg'">
                <span x-text="(data.rows[0].cash_on_hand >= 0 ? '£' : '-£') + Math.abs(+data.rows[0].cash_on_hand || 0).toLocaleString('en-GB', {maximumFractionDigits:0})"></span>
              </div>
            </div>
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-slate-500">Open actions</div>
              <div class="text-2xl mono font-semibold mt-1" x-text="data.rows[0].open_actions_count || 0"></div>
            </div>
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-slate-500">Docs expiring 60d</div>
              <div class="text-2xl mono font-semibold mt-1" x-text="data.rows[0].docs_expiring_60d || 0"></div>
            </div>
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-slate-500">Calendar 7d</div>
              <div class="text-2xl mono font-semibold mt-1" x-text="data.rows[0].calendar_7d || 0"></div>
            </div>
          </div>
        </template>'''
    elif kind == 'kpi4-forensic':
        body = '''
        <template x-if="loading"><div class="grid grid-cols-2 md:grid-cols-4 gap-2">
          <div class="skel h-20"></div><div class="skel h-20"></div>
          <div class="skel h-20"></div><div class="skel h-20"></div></div></template>
        <template x-if="!loading && data && data.rows && data.rows[0]">
          <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-rose-300">Critical</div>
              <div class="text-2xl mono font-semibold mt-1" x-text="data.rows[0].critical_open || 0"></div>
            </div>
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-amber-300">High</div>
              <div class="text-2xl mono font-semibold mt-1" x-text="data.rows[0].high_open || 0"></div>
            </div>
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-yellow-200">Medium</div>
              <div class="text-2xl mono font-semibold mt-1" x-text="data.rows[0].medium_open || 0"></div>
            </div>
            <div class="bg-black/30 rounded-md p-3">
              <div class="text-xs uppercase tracking-wider text-slate-500">Raised 24h</div>
              <div class="text-2xl mono font-semibold mt-1" x-text="data.rows[0].raised_24h || 0"></div>
              <div class="text-xs text-emerald-300 mt-1">Resolved: <span x-text="data.rows[0].resolved_24h || 0"></span></div>
            </div>
          </div>
        </template>'''
    elif kind == 't03-bookings':
        body = '''
        <template x-if="loading"><div class="space-y-2"><div class="skel h-10"></div><div class="skel h-10"></div></div></template>
        <template x-if="!loading && data && data.rows && data.rows.length === 0">
          <div class="text-slate-400 text-sm py-2">No check-ins today.</div></template>
        <template x-if="!loading && data && data.rows && data.rows.length > 0">
          <div class="overflow-x-auto"><table class="w-full text-sm">
            <thead class="text-xs uppercase tracking-wider text-slate-500">
              <tr><th class="text-left px-2 py-2">Guest</th><th class="text-left px-2 py-2">Room</th>
                  <th class="text-left px-2 py-2">Out</th><th class="text-left px-2 py-2">Source</th>
                  <th class="text-right px-2 py-2">Gross</th></tr></thead>
            <tbody>
              <template x-for="b in data.rows" :key="b.id">
                <tr class="border-t border-white/5">
                  <td class="px-2 py-2 text-zinc-100" x-text="b.guest_name || '—'"></td>
                  <td class="px-2 py-2 text-slate-300" x-text="b.room || '—'"></td>
                  <td class="px-2 py-2 mono text-slate-400" x-text="b.checkout_date || '—'"></td>
                  <td class="px-2 py-2 mono text-xs text-slate-400" x-text="b.source + ' #' + b.source_ref"></td>
                  <td class="px-2 py-2 mono text-right">£<span x-text="(+b.gross_amount || 0).toFixed(2)"></span></td>
                </tr></template>
              <tr class="border-t-2 border-white/10 font-medium">
                <td class="px-2 py-2" colspan="4">Total · <span x-text="data.rows.length"></span> booking(s)</td>
                <td class="px-2 py-2 mono text-right pos">£<span x-text="data.rows.reduce((s,r) => s + (+r.gross_amount || 0), 0).toFixed(2)"></span></td>
              </tr></tbody></table></div></template>'''
    elif kind == 't04-pub-sales':
        body = '''
        <template x-if="loading"><div class="skel h-24"></div></template>
        <template x-if="!loading && data && data.rows && data.rows.length === 0">
          <div class="text-slate-400 text-sm py-2">No TouchOffice sales scraped yet for today.</div></template>
        <template x-if="!loading && data && data.rows && data.rows.length > 0">
          <div class="overflow-x-auto"><table class="w-full text-sm">
            <thead class="text-xs uppercase tracking-wider text-slate-500">
              <tr><th class="text-left px-2 py-2">Site</th><th class="text-left px-2 py-2">Department</th>
                  <th class="text-right px-2 py-2">Qty</th><th class="text-right px-2 py-2">Net</th></tr></thead>
            <tbody><template x-for="row in data.rows" :key="row.site + '|' + row.department">
              <tr class="border-t border-white/5">
                <td class="px-2 py-2"><span class="px-2 py-0.5 rounded text-xs"
                  :class="row.site === 'malthouse' ? 'bg-amber-500/15 text-amber-200' : 'bg-emerald-500/15 text-emerald-200'"
                  x-text="row.site === 'malthouse' ? 'Pub' : 'Cafe'"></span></td>
                <td class="px-2 py-2 text-zinc-200" x-text="row.department"></td>
                <td class="px-2 py-2 mono text-right text-slate-400" x-text="(+row.quantity || 0).toFixed(0)"></td>
                <td class="px-2 py-2 mono text-right pos">£<span x-text="(+row.net_value || 0).toFixed(2)"></span></td>
              </tr></template>
              <tr class="border-t-2 border-white/10 font-medium">
                <td class="px-2 py-2" colspan="3">Total</td>
                <td class="px-2 py-2 mono text-right pos">£<span x-text="data.rows.reduce((s,r) => s + (+r.net_value || 0), 0).toFixed(2)"></span></td>
              </tr></tbody></table></div></template>'''
    elif kind == 'a01-actions':
        body = '''
        <div x-data="{ filter: 'all' }">
          <div class="flex flex-wrap gap-1 mb-3 text-xs">
            <button @click="filter = 'all'" :aria-pressed="filter === 'all'"
                    class="px-2 py-1 min-h-[32px] rounded"
                    :class="filter === 'all' ? 'bg-white/10 text-zinc-100' : 'bg-white/5 text-zinc-400'">All</button>
            <button @click="filter = 'critical'" :aria-pressed="filter === 'critical'"
                    class="px-2 py-1 min-h-[32px] rounded"
                    :class="filter === 'critical' ? 'bg-red-500/20 text-red-200' : 'bg-white/5 text-zinc-400'">Critical</button>
            <button @click="filter = 'high'" :aria-pressed="filter === 'high'"
                    class="px-2 py-1 min-h-[32px] rounded"
                    :class="filter === 'high' ? 'bg-amber-500/20 text-amber-200' : 'bg-white/5 text-zinc-400'">High</button>
            <button @click="filter = 'medium'" :aria-pressed="filter === 'medium'"
                    class="px-2 py-1 min-h-[32px] rounded"
                    :class="filter === 'medium' ? 'bg-yellow-500/20 text-yellow-200' : 'bg-white/5 text-zinc-400'">Medium</button>
          </div>
          <template x-if="loading"><div class="skel h-40"></div></template>
          <template x-if="!loading && data && data.rows">
            <div class="overflow-x-auto"><table class="w-full text-sm">
              <thead class="text-xs uppercase tracking-wider text-slate-500">
                <tr><th class="text-left px-2 py-2 w-6"></th><th class="text-left px-2 py-2">Title</th>
                    <th class="text-left px-2 py-2">Kind</th><th class="text-left px-2 py-2">Source</th>
                    <th class="text-left px-2 py-2">Realm</th><th class="text-right px-2 py-2">Age</th></tr></thead>
              <tbody><template x-for="a in (filter === 'all' ? data.rows : data.rows.filter(r => r.severity === filter)).slice(0, 50)" :key="a.source + ':' + a.ref">
                <tr class="border-t border-white/5">
                  <td class="px-2 py-2"><span class="tl"
                    :class="{ 'tl-red': a.severity === 'critical', 'tl-amber': a.severity === 'high',
                              'tl-green': a.severity === 'medium', 'tl-grey': a.severity === 'low' }"></span></td>
                  <td class="px-2 py-2 text-zinc-100"><span class="block max-w-md truncate" :title="a.title" x-text="a.title"></span></td>
                  <td class="px-2 py-2 text-xs mono text-slate-400" x-text="a.kind"></td>
                  <td class="px-2 py-2 text-xs mono text-slate-400" x-text="a.source"></td>
                  <td class="px-2 py-2 text-xs">
                    <span class="px-1.5 py-0.5 rounded"
                          :class="a.realm === 'work' ? 'bg-amber-500/15 text-amber-200' :
                                   a.realm === 'family' ? 'bg-emerald-500/15 text-emerald-200' :
                                   'bg-slate-500/15 text-slate-300'" x-text="a.realm"></span></td>
                  <td class="px-2 py-2 mono text-right text-slate-400" x-text="a.age_days + 'd'"></td>
                </tr></template></tbody></table></div></template>
        </div>'''
    elif kind == 'r01-registry':
        # Render the static section registry from this file
        rows_html = '\n'.join(
            f'<tr class="border-t border-white/5"><td class="px-2 py-2 mono text-amber-300">§{code}</td>'
            f'<td class="px-2 py-2 text-zinc-100">{info["name"]}</td>'
            f'<td class="px-2 py-2 text-xs mono text-slate-400">{info["slug"] or "(no slug)"}</td>'
            f'<td class="px-2 py-2 text-xs text-slate-500">{info["kind"]}</td></tr>'
            for code, info in sorted(SECTIONS.items())
        )
        body = f'''<div class="overflow-x-auto"><table class="w-full text-sm">
          <thead class="text-xs uppercase tracking-wider text-slate-500">
            <tr><th class="text-left px-2 py-2">Code</th><th class="text-left px-2 py-2">Name</th>
                <th class="text-left px-2 py-2">Slug</th><th class="text-left px-2 py-2">Kind</th></tr></thead>
          <tbody>{rows_html}</tbody></table></div>'''
    elif kind == 'note':
        note_text = s.get('note', '')
        body = f'<div class="text-sm text-slate-400 py-2">{note_text}</div>'
    elif kind == 'table':
        # Generic table that auto-discovers columns from the first row
        body = '''
        <template x-if="loading"><div class="skel h-32"></div></template>
        <template x-if="error"><div class="text-red-300 text-sm">Couldn't load: <span x-text="error"></span></div></template>
        <template x-if="!loading && !error && data && data.rows && data.rows.length === 0">
          <div class="text-slate-400 text-sm py-2">No rows.</div></template>
        <template x-if="!loading && !error && data && data.rows && data.rows.length > 0">
          <div class="overflow-x-auto"><table class="w-full text-sm">
            <thead class="text-xs uppercase tracking-wider text-slate-500">
              <tr><template x-for="k in Object.keys(data.rows[0])" :key="k">
                <th class="text-left px-2 py-2" x-text="k"></th></template></tr></thead>
            <tbody><template x-for="(r, i) in data.rows.slice(0, 100)" :key="i">
              <tr class="border-t border-white/5">
                <template x-for="k in Object.keys(data.rows[0])" :key="k">
                  <td class="px-2 py-2"
                      :class="typeof r[k] === 'number' ? 'mono text-right' : 'text-zinc-100'"
                      x-text="r[k] === null ? '—' : (typeof r[k] === 'object' ? JSON.stringify(r[k]) : r[k])"></td>
                </template></tr></template></tbody></table>
            <div class="text-xs text-slate-500 mt-2"
                 x-text="data.rows.length > 100 ? `${data.rows.length} rows, first 100 shown` : `${data.rows.length} row(s)`"></div>
          </div></template>'''
    else:
        body = f'<div class="text-amber-300 text-sm">unknown kind: {kind}</div>'

    return textwrap.dedent(f'''
      <section id="{code}" data-section-code="{code}"
               class="glass rounded-lg p-4 mb-4"
               x-data="desktopSection({{ code: '{code}', name: {name!r}, {slug_attr} }})"
               x-init="init()" aria-labelledby="{code}-h">
        <header class="flex items-baseline justify-between mb-3">
          <h2 id="{code}-h" class="text-base font-semibold">
            <span class="mono text-xs text-amber-300">§{code}</span>
            {name}
          </h2>
          <span class="text-xs text-slate-500" x-text="lastRefresh"></span>
        </header>
        {body}
      </section>''').rstrip()


def render_page(path: str) -> str:
    bucket, page, page_name, codes = PAGES[path]
    bucket_color = {'work': 'amber', 'private': 'emerald', 'build': 'violet', 'all': 'slate'}.get(bucket, 'slate')

    sections_html = '\n'.join(render_section(c) for c in codes if c in SECTIONS)

    # Build the rail's "on this page" list
    on_page_items = ''.join(
        f'<li><a href="#{c}" class="rail-link cursor-pointer" :class="{{\'active\': isActive(\'{c}\')}}" '
        f'@click.prevent="scrollTo(\'{c}\')">'
        f'<span class="rail-code">§{c}</span><span>{SECTIONS[c]["name"]}</span></a></li>'
        for c in codes if c in SECTIONS
    )

    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#0a0a0b">
<title>{page_name} · {bucket.title()} — Home AI</title>
<script src="/static/vendor/tailwind-3.4.min.js"></script>
<script defer src="/static/vendor/alpine-3.14.min.js"></script>
<script src="/static/_components/realm-toggle.js"></script>
<script src="/static/_components/date-window.js"></script>
<script src="/static/_components/desktop-chrome.js"></script>
<style>
  :root {{ color-scheme: dark; }}
  body {{ background: linear-gradient(180deg, #0f172a 0%, #020617 100%); min-height: 100vh; color: #e2e8f0;
         font-family: ui-sans-serif, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }}
  .glass {{ background: rgba(15,23,42,0.7); border: 1px solid rgba(148,163,184,0.15); }}
  .mono {{ font-family: "JetBrains Mono", ui-monospace, monospace; font-variant-numeric: tabular-nums; }}
  .pos{{color:#34d399}}.neg{{color:#f43f5e}}
  .tl{{display:inline-block;width:9px;height:9px;border-radius:999px;margin-right:6px;vertical-align:middle;box-shadow:0 0 6px currentColor}}
  .tl-red{{background:#f43f5e;color:#f43f5e;animation:pulse 1.4s infinite}}.tl-amber{{background:#f59e0b;color:#f59e0b}}.tl-green{{background:#10b981;color:#10b981}}.tl-grey{{background:#64748b;color:#64748b}}
  @keyframes pulse{{50%{{opacity:0.55}}}}
  .skel{{background:linear-gradient(90deg,rgba(148,163,184,0.06) 0%,rgba(148,163,184,0.12) 50%,rgba(148,163,184,0.06) 100%);background-size:200% 100%;animation:shimmer 1.4s ease-in-out infinite;border-radius:6px}}
  @keyframes shimmer{{0%{{background-position:200% 0}}100%{{background-position:-200% 0}}}}
  section[data-section-code]{{scroll-margin-top:72px}}
  .rail-link{{display:flex;align-items:center;min-height:36px;padding:4px 10px;border-radius:6px;color:#a1a1aa}}
  .rail-link:hover{{background:rgba(255,255,255,0.05);color:#e2e8f0}}
  .rail-link.active{{background:rgba(245,158,11,0.15);color:#fcd34d}}
  .rail-code{{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:0.75rem;color:#71717a;margin-right:8px}}
  .rail-link.active .rail-code{{color:#fbbf24}}
  [x-cloak]{{display:none!important}}
</style>
</head>
<body x-data="desktopShell({{ bucket: {bucket!r}, page: {page!r}, pageName: {page_name!r} }})" x-init="init()">

<header class="sticky top-0 z-40 backdrop-blur-md bg-slate-950/85 border-b border-white/5"
        x-data="homeaiHeader()" x-init="boot()">
  <div class="px-3 py-2 flex items-center gap-2">
    <button type="button"
            class="min-h-[44px] min-w-[44px] rounded-md hover:bg-white/5
                   focus-visible:ring-2 focus-visible:ring-amber-400/60 focus-visible:outline-none"
            :aria-label="$root.railOpen ? 'Close menu' : 'Open menu'"
            @click="$root.toggleRail()">
      <svg xmlns="http://www.w3.org/2000/svg" class="inline w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
        <path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 12h16M4 18h16"/></svg></button>
    <a href="/" class="flex items-center gap-2 text-zinc-100 min-h-[44px]" aria-label="Home AI">
      <span class="text-xl leading-none">⌂</span><span class="font-semibold text-sm">Home AI</span></a>
    <div class="ml-2 flex bg-white/5 rounded-lg p-0.5 text-sm min-h-[44px] items-center" role="tablist" aria-label="Realm filter">
      <button type="button" role="tab" :aria-selected="realm === 'work'" :tabindex="realm === 'work' ? 0 : -1"
              class="px-3 min-h-[44px] min-w-[44px] rounded-md transition focus-visible:ring-2 focus-visible:ring-amber-400/60"
              :class="realm === 'work' ? 'bg-amber-500/20 text-amber-200 ring-1 ring-amber-500/40' : 'text-zinc-400 hover:text-zinc-200'"
              @click="setRealm('work')" @keydown.right.prevent="setRealm('all')" @keydown.left.prevent="setRealm('work')">Work</button>
      <button type="button" role="tab" :aria-selected="realm === 'all'" :tabindex="realm === 'all' ? 0 : -1"
              class="px-3 min-h-[44px] min-w-[44px] rounded-md transition focus-visible:ring-2 focus-visible:ring-emerald-400/60"
              :class="realm === 'all' ? 'bg-emerald-500/20 text-emerald-200 ring-1 ring-emerald-500/40' : 'text-zinc-400 hover:text-zinc-200'"
              @click="setRealm('all')" @keydown.right.prevent="setRealm('all')" @keydown.left.prevent="setRealm('work')">All</button>
    </div>
    <div class="ml-auto md:ml-4">
      <div x-data="dateWindow({{ pageKey: {path!r}, defaultPreset: '7d' }})" x-init="init()"
           class="flex bg-white/5 rounded-lg p-0.5 text-sm min-h-[44px] items-center" role="group" aria-label="Date window">
        <template x-for="p in presets" :key="p.id">
          <button type="button" :aria-pressed="isActive(p.id)"
                  class="px-3 min-h-[36px] rounded-md text-xs transition focus-visible:ring-2 focus-visible:ring-amber-400/60 focus-visible:outline-none"
                  :class="isActive(p.id) ? 'bg-amber-500/20 text-amber-200' : 'text-zinc-400 hover:text-zinc-200'"
                  @click="setPreset(p.id)" x-text="p.label"></button>
        </template></div></div>
    <a href="/" class="px-2 min-h-[44px] flex items-center rounded-md text-zinc-400 hover:text-zinc-100 text-sm" title="Mobile view">📱</a>
  </div>
  <nav class="px-3 pb-2 text-xs text-zinc-400" aria-label="Breadcrumb" x-data="desktopBreadcrumbs()" x-init="init()">
    <a :href="bucketUrl()" class="hover:text-zinc-200" x-text="bucket === 'work' ? 'Work' : bucket === 'private' ? 'Private' : bucket === 'build' ? 'Build' : 'All'"></a>
    <span class="mx-1" aria-hidden="true">›</span>
    <a :href="pageUrl()" class="hover:text-zinc-200" x-text="pageName"></a>
    <template x-if="activeSectionLabel"><span><span class="mx-1" aria-hidden="true">›</span>
      <span class="text-zinc-100" aria-current="page" x-text="activeSectionLabel"></span></span></template>
  </nav>
</header>
<script>
  window.homeaiHeader = function () {{ return {{
    realm: 'work',
    boot() {{ this.realm = (window.HomeAI && window.HomeAI.getRealm()) || 'work';
      window.addEventListener('realm-changed', (e) => {{ this.realm = e.detail.realm; }}); }},
    setRealm(next) {{ if (window.HomeAI?.setRealm) window.HomeAI.setRealm(next); }} }}; }};
</script>

<div class="flex">
  <aside id="rail"
         class="fixed lg:sticky top-[88px] z-30 w-64 h-[calc(100vh-88px)] overflow-y-auto
                bg-slate-950/95 border-r border-white/5 px-2 py-3 transition-transform lg:translate-x-0"
         :class="railOpen ? 'translate-x-0' : '-translate-x-full'" aria-label="Sections">
    <details open class="mb-2"><summary class="cursor-pointer px-2 py-1 text-xs uppercase tracking-wider text-amber-300">Work</summary>
      <ul class="space-y-0.5 ml-1">
        <li><a href="/desktop/work/today" class="rail-link" :class="{{'active': $root.bucket === 'work' && $root.page === 'today'}}">Today</a></li>
        <li><a href="/desktop/work/actions" class="rail-link" :class="{{'active': $root.bucket === 'work' && $root.page === 'actions'}}">Actions</a></li>
        <li><a href="/desktop/work/docs" class="rail-link" :class="{{'active': $root.bucket === 'work' && $root.page === 'docs'}}">Docs</a></li>
        <li><a href="/desktop/work/staff" class="rail-link" :class="{{'active': $root.bucket === 'work' && $root.page === 'staff'}}">Staff</a></li>
        <li><a href="/desktop/work/email" class="rail-link" :class="{{'active': $root.bucket === 'work' && $root.page === 'email'}}">Email</a></li>
        <li><a href="/desktop/work/finance" class="rail-link" :class="{{'active': $root.bucket === 'work' && $root.page === 'finance'}}">Finance</a></li>
      </ul></details>
    <details class="mb-2"><summary class="cursor-pointer px-2 py-1 text-xs uppercase tracking-wider text-emerald-300">Private</summary>
      <ul class="space-y-0.5 ml-1">
        <li><a href="/desktop/private/today" class="rail-link" :class="{{'active': $root.bucket === 'private' && $root.page === 'today'}}">Today</a></li>
        <li><a href="/desktop/private/family" class="rail-link" :class="{{'active': $root.bucket === 'private' && $root.page === 'family'}}">Family</a></li>
        <li><a href="/desktop/private/docs" class="rail-link" :class="{{'active': $root.bucket === 'private' && $root.page === 'docs'}}">Docs</a></li>
      </ul></details>
    <details class="mb-2"><summary class="cursor-pointer px-2 py-1 text-xs uppercase tracking-wider text-violet-300">Build</summary>
      <ul class="space-y-0.5 ml-1">
        <li><a href="/desktop/build/pipelines" class="rail-link" :class="{{'active': $root.bucket === 'build' && $root.page === 'pipelines'}}">Pipelines</a></li>
        <li><a href="/desktop/build/models" class="rail-link" :class="{{'active': $root.bucket === 'build' && $root.page === 'models'}}">Models</a></li>
        <li><a href="/desktop/build/forensics" class="rail-link" :class="{{'active': $root.bucket === 'build' && $root.page === 'forensics'}}">Forensics</a></li>
      </ul></details>
    <details class="mb-2"><summary class="cursor-pointer px-2 py-1 text-xs uppercase tracking-wider text-slate-300">All</summary>
      <ul class="space-y-0.5 ml-1">
        <li><a href="/desktop/all" class="rail-link" :class="{{'active': $root.bucket === 'all'}}">Sitemap</a></li>
      </ul></details>
    <div class="mt-3 pt-3 border-t border-white/5">
      <div class="px-2 py-1 text-xs uppercase tracking-wider text-zinc-500">On this page</div>
      <ul class="space-y-0.5 ml-1">{on_page_items}</ul>
    </div>
  </aside>
  <div x-show="railOpen && !isWide" x-cloak class="fixed inset-0 top-[88px] z-20 bg-black/40 lg:hidden" @click="closeRail()"></div>
  <main class="flex-1 min-w-0 lg:ml-0 px-4 py-4 max-w-5xl">
{sections_html}
  </main>
</div>
</body></html>'''


def main():
    written = 0
    for path in PAGES:
        out = STATIC / page_filename(path)
        out.write_text(render_page(path))
        written += 1
        print(f'  wrote {out.name}  ({out.stat().st_size} bytes)')
    print(f'\n=== Generated {written} desktop pages ===')

if __name__ == '__main__':
    main()
