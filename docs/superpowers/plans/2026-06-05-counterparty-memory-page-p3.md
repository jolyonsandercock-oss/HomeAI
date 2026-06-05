# Counterparty Memory Page (P3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A browsable owner-only `/app/memory` page — a searchable/filterable counterparty directory plus a per-counterparty dossier view (summary, financials, people, open threads, citations) — over the P1 registry and P2 dossiers.

**Architecture:** Two read-only GET APIs on build-dashboard (`/api/memory/counterparties` list, `/api/memory/counterparty/{id}` detail+dossier), both owner-gated like the P2 endpoints, plus a self-contained `static/memory.html` (Tailwind + Alpine + Tabulator, mirroring `static/coverage.html`) served at `/app/memory`. A "Distil now" button reuses P2's lazy `POST /api/memory/dossier/{id}`.

**Tech Stack:** FastAPI (build-dashboard `main.py`: `db_all`, `_isoify`, `_decode_dossier`, `_current_realm`, `Query`, `JSONResponse`, `FileResponse`, `STATIC`), front-end = Tailwind/Alpine/Tabulator via CDN + `/static/css/tables.css`. **No pytest** — tests are `curl` smoke checks against build-dashboard at `http://100.104.82.53:8090`.

**Depends on:** P1 (`counterparties`) + P2 (`counterparty_dossier`, `/api/memory/*` POST endpoints, `_decode_dossier`). **Spec:** `docs/superpowers/specs/2026-06-05-counterparty-cultural-memory-design.md` §6.

**Owner-only:** cultural memory is owner-only (P2 decision). Both new GETs return 403 for non-owner; the page is served under the owner Authelia tier (same as `/build`, `/admin`).

---

## File Structure

- Modify: `services/build-dashboard/main.py` — add `GET /api/memory/counterparties`, `GET /api/memory/counterparty/{id}`, `GET /app/memory` (place beside the P2 `/api/memory/*` block).
- Create: `services/build-dashboard/static/memory.html` — directory + dossier drawer.

## Conventions

- Edit + rebuild build-dashboard (main.py and static/ are BAKED into the image): `cd /home_ai && python3 -m py_compile services/build-dashboard/main.py && docker compose build build-dashboard && docker compose up -d --no-deps build-dashboard`. Health: `curl -s http://100.104.82.53:8090/api/healthz`.
- All API smoke tests send `-H 'X-Realm: owner'`.

---

### Task 1: List API — `GET /api/memory/counterparties`

**Files:**
- Modify: `services/build-dashboard/main.py` (add after the P2 `distill-batch` endpoint)

- [ ] **Step 1: Add the endpoint**

Insert in `services/build-dashboard/main.py` after the `api_memory_distill_batch` function:

```python
@app.get("/api/memory/counterparties")
async def api_memory_counterparties(
        q: str = Query(""),
        include_automated: bool = Query(False),
        has_spend: bool = Query(False),
        watchlist: bool = Query(False),
        limit: int = Query(500, ge=1, le=2000)):
    """Owner-only counterparty directory, ranked by signal_score."""
    if _current_realm.get() != "owner":
        return JSONResponse({"error": "cultural memory is owner-only"}, status_code=403)
    rows = await db_all("""
        SELECT c.id, c.kind, c.display_name, c.domain, c.email_count,
               c.last_seen, c.linked_vendor, c.signal_score, c.is_automated,
               c.on_watchlist,
               (d.counterparty_id IS NOT NULL) AS has_dossier
          FROM counterparties c
          LEFT JOIN counterparty_dossier d ON d.counterparty_id = c.id
         WHERE ($1 = '' OR c.display_name ILIKE '%'||$1||'%' OR c.domain ILIKE '%'||$1||'%')
           AND ($2 OR NOT c.is_automated)
           AND (NOT $3 OR c.linked_vendor IS NOT NULL)
           AND (NOT $4 OR c.on_watchlist)
         ORDER BY c.signal_score DESC NULLS LAST
         LIMIT $5
    """, q, include_automated, has_spend, watchlist, limit)
    return {"n": len(rows), "rows": [_isoify(dict(r)) for r in rows]}
```

- [ ] **Step 2: Build, recreate, smoke-test**

```bash
cd /home_ai && python3 -m py_compile services/build-dashboard/main.py && echo COMPILE_OK
docker compose build build-dashboard && docker compose up -d --no-deps build-dashboard
sleep 5; curl -s http://100.104.82.53:8090/api/healthz
echo "--- owner list (default: non-automated, top by signal) ---"
curl -s -H 'X-Realm: owner' "http://100.104.82.53:8090/api/memory/counterparties?limit=5" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("n=",d["n"]);[print(" ",r["display_name"],"| spend?",bool(r["linked_vendor"]),"| dossier?",r["has_dossier"]) for r in d["rows"]]'
echo "--- search + has_spend filter ---"
curl -s -H 'X-Realm: owner' "http://100.104.82.53:8090/api/memory/counterparties?has_spend=true&limit=3" \
  | python3 -c 'import sys,json;print("linked-only n=",json.load(sys.stdin)["n"])'
echo "--- non-owner MUST be 403 ---"
curl -s -o /dev/null -w "work=%{http_code}\n" -H 'X-Realm: work' "http://100.104.82.53:8090/api/memory/counterparties"
```
Expected: `COMPILE_OK`, healthz ok, owner list returns 5 ranked rows, has_spend list non-empty, `work=403`.

- [ ] **Step 3: Commit**

```bash
git add services/build-dashboard/main.py
git commit -m "U242 P3: GET /api/memory/counterparties (owner-only directory)"
```

---

### Task 2: Detail API — `GET /api/memory/counterparty/{id}`

**Files:**
- Modify: `services/build-dashboard/main.py` (add after Task 1's endpoint)

- [ ] **Step 1: Add the endpoint**

Insert after `api_memory_counterparties`:

```python
@app.get("/api/memory/counterparty/{cp_id}")
async def api_memory_counterparty(cp_id: int):
    """Owner-only: counterparty + its cached dossier (dossier null if not distilled)."""
    if _current_realm.get() != "owner":
        return JSONResponse({"error": "cultural memory is owner-only"}, status_code=403)
    cp = await db_all("SELECT * FROM counterparties WHERE id=$1", cp_id)
    if not cp:
        return JSONResponse({"error": "not found"}, status_code=404)
    dos = await db_all("SELECT * FROM counterparty_dossier WHERE counterparty_id=$1", cp_id)
    dossier = _decode_dossier(_isoify(dict(dos[0]))) if dos else None
    return {"counterparty": _isoify(dict(cp[0])), "dossier": dossier}
```

- [ ] **Step 2: Build, recreate, smoke-test**

```bash
cd /home_ai && python3 -m py_compile services/build-dashboard/main.py && echo COMPILE_OK
docker compose build build-dashboard && docker compose up -d --no-deps build-dashboard
sleep 5
echo "--- detail for an already-distilled counterparty (financials as object, parsed dossier) ---"
curl -s -H 'X-Realm: owner' "http://100.104.82.53:8090/api/memory/counterparty/641" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);c=d["counterparty"];dz=d["dossier"];print("cp:",c["display_name"]);print("has_dossier:",dz is not None);print("financials:",dz and dz["financials"]);print("summary:",(dz or {}).get("summary","")[:120])'
echo "--- non-owner MUST be 403 ---"
curl -s -o /dev/null -w "work=%{http_code}\n" -H 'X-Realm: work' "http://100.104.82.53:8090/api/memory/counterparty/641"
echo "--- missing id MUST be 404 ---"
curl -s -o /dev/null -w "missing=%{http_code}\n" -H 'X-Realm: owner' "http://100.104.82.53:8090/api/memory/counterparty/99999999"
```
Expected: detail shows `financials` as an object and a non-empty summary; `work=403`; `missing=404`.

- [ ] **Step 3: Commit**

```bash
git add services/build-dashboard/main.py
git commit -m "U242 P3: GET /api/memory/counterparty/{id} (detail + cached dossier)"
```

---

### Task 3: The page — `static/memory.html` + route `/app/memory`

**Files:**
- Create: `services/build-dashboard/static/memory.html`
- Modify: `services/build-dashboard/main.py` (add the route)

- [ ] **Step 1: Add the route**

Insert in `main.py` near the other page routes (e.g. after the `/documents` route ~line 3757):

```python
@app.get("/app/memory")
async def memory_page():
    return FileResponse(str(STATIC / "memory.html"))
```

- [ ] **Step 2: Create the page**

Create `services/build-dashboard/static/memory.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cultural memory — Home AI</title>
<script src="https://cdn.tailwindcss.com"></script>
<script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js"></script>
<link href="https://unpkg.com/tabulator-tables@5.5.4/dist/css/tabulator.min.css" rel="stylesheet">
<link href="/static/css/tables.css" rel="stylesheet">
<script src="https://unpkg.com/tabulator-tables@5.5.4/dist/js/tabulator.min.js"></script>
<style>
  :root { color-scheme: dark; }
  body { background: radial-gradient(ellipse at top, #0f172a, #020617 60%); min-height: 100vh; font-family: ui-sans-serif, system-ui, sans-serif; }
  .glass { background: rgba(15,23,42,0.7); backdrop-filter: blur(10px); border: 1px solid rgba(148,163,184,0.15); }
  .muted { color: #94a3b8; }
  .chip { background: rgba(148,163,184,0.15); border-radius: 9999px; padding: 1px 8px; font-size: 11px; }
</style>
</head>
<body class="text-slate-100">
<div x-data="memoryPage()" x-init="boot()" class="max-w-7xl mx-auto p-4 md:p-6 space-y-5">

  <header class="flex flex-wrap items-center justify-between gap-3">
    <div>
      <h1 class="text-2xl md:text-3xl font-semibold tracking-tight">Cultural memory</h1>
      <p class="text-sm muted">Everyone you correspond with — searchable directory with distilled dossiers.</p>
    </div>
    <a href="/" class="text-xs muted hover:text-slate-200">← Mission Control</a>
  </header>

  <section class="glass rounded-xl p-3 md:p-4 space-y-3">
    <div class="flex flex-wrap items-center gap-3">
      <input type="text" x-model="q" @input.debounce.300ms="load()" placeholder="Search name or domain…"
             class="bg-slate-900/60 border border-slate-700 rounded px-3 py-1.5 text-sm w-64">
      <label class="text-xs muted flex items-center gap-1"><input type="checkbox" x-model="hasSpend" @change="load()"> has spend</label>
      <label class="text-xs muted flex items-center gap-1"><input type="checkbox" x-model="watchlist" @change="load()"> watchlist</label>
      <label class="text-xs muted flex items-center gap-1"><input type="checkbox" x-model="includeAutomated" @change="load()"> show automated</label>
      <span class="text-xs muted" x-text="`${n} shown`"></span>
    </div>
    <div id="cp-table"></div>
  </section>

  <!-- Dossier drawer -->
  <section x-show="selected" class="glass rounded-xl p-4 md:p-5 space-y-4">
    <div class="flex items-start justify-between gap-3">
      <div>
        <h2 class="text-xl font-semibold" x-text="selected?.counterparty?.display_name"></h2>
        <p class="text-xs muted" x-text="`${selected?.counterparty?.kind} · ${selected?.counterparty?.domain || ''} · ${selected?.counterparty?.email_count} emails`"></p>
      </div>
      <div class="flex gap-2">
        <button @click="distil()" :disabled="distilling"
                class="text-xs bg-indigo-600/80 hover:bg-indigo-500 rounded px-3 py-1.5 disabled:opacity-50"
                x-text="distilling ? 'Distilling…' : (selected?.dossier ? 'Refresh' : 'Distil now')"></button>
        <button @click="selected=null" class="text-xs muted hover:text-slate-200">✕</button>
      </div>
    </div>

    <template x-if="selected?.dossier">
      <div class="space-y-4">
        <div>
          <h3 class="text-sm font-medium muted mb-1">Summary</h3>
          <p class="text-sm whitespace-pre-wrap" x-text="selected.dossier.summary"></p>
        </div>
        <div class="grid md:grid-cols-2 gap-4">
          <div>
            <h3 class="text-sm font-medium muted mb-1">Financials</h3>
            <p class="text-sm" x-text="fmtFin(selected.dossier.financials)"></p>
          </div>
          <div x-show="(selected.dossier.people||[]).length">
            <h3 class="text-sm font-medium muted mb-1">People</h3>
            <ul class="text-sm space-y-0.5">
              <template x-for="p in (selected.dossier.people||[])" :key="p.email||p.name">
                <li><span x-text="p.name"></span> <span class="muted" x-text="p.role ? '· '+p.role : ''"></span></li>
              </template>
            </ul>
          </div>
        </div>
        <div x-show="(selected.dossier.open_threads||[]).length">
          <h3 class="text-sm font-medium muted mb-1">Open threads</h3>
          <ul class="text-sm space-y-0.5">
            <template x-for="t in (selected.dossier.open_threads||[])" :key="t.email_id">
              <li><span x-text="t.subject"></span> <span class="chip" x-text="t.status"></span></li>
            </template>
          </ul>
        </div>
        <div x-show="(selected.dossier.citations||[]).length">
          <h3 class="text-sm font-medium muted mb-1" x-text="`Citations (${selected.dossier.citations.length} emails)`"></h3>
          <div class="flex flex-wrap gap-1">
            <template x-for="cid in selected.dossier.citations" :key="cid">
              <span class="chip" x-text="'email #'+cid"></span>
            </template>
          </div>
        </div>
      </div>
    </template>
    <p x-show="selected && !selected.dossier" class="text-sm muted">No dossier yet — click “Distil now”.</p>
  </section>
</div>

<script>
function memoryPage() {
  return {
    q: '', hasSpend: false, watchlist: false, includeAutomated: false,
    n: 0, table: null, selected: null, distilling: false,
    async boot() {
      this.table = new Tabulator('#cp-table', {
        layout: 'fitColumns', height: '55vh', pagination: true, paginationSize: 25,
        placeholder: 'No counterparties match.',
        columns: [
          { title:'Name', field:'display_name', widthGrow:3 },
          { title:'Domain', field:'domain', widthGrow:2,
            formatter: c => `<span class="muted">${c.getValue()||''}</span>` },
          { title:'Emails', field:'email_count', width:90, hozAlign:'right' },
          { title:'Spend', field:'linked_vendor', width:90, hozAlign:'center',
            formatter: c => c.getValue() ? '£' : '' },
          { title:'Dossier', field:'has_dossier', width:90, hozAlign:'center',
            formatter: c => c.getValue() ? '<span class="pct-good">✓</span>' : '' },
          { title:'Signal', field:'signal_score', width:90, hozAlign:'right',
            formatter: c => Number(c.getValue()||0).toFixed(1) },
        ],
      });
      this.table.on('rowClick', (e, row) => this.open(row.getData().id));
      this.load();
    },
    async load() {
      const p = new URLSearchParams({
        q: this.q, has_spend: this.hasSpend, watchlist: this.watchlist,
        include_automated: this.includeAutomated, limit: 500,
      });
      const r = await fetch('/api/memory/counterparties?' + p, { headers: { 'X-Realm': 'owner' } }).then(r => r.json());
      this.n = r.n || 0;
      this.table.setData(r.rows || []);
    },
    async open(id) {
      this.selected = await fetch('/api/memory/counterparty/' + id, { headers: { 'X-Realm': 'owner' } }).then(r => r.json());
    },
    async distil() {
      if (!this.selected) return;
      this.distilling = true;
      try {
        await fetch('/api/memory/dossier/' + this.selected.counterparty.id + '?refresh=true',
                    { method: 'POST', headers: { 'X-Realm': 'owner' } });
        await this.open(this.selected.counterparty.id);
        this.load();
      } finally { this.distilling = false; }
    },
    fmtFin(f) {
      if (!f || f.total_invoiced == null) return 'No invoices on file.';
      const n = Number(f.total_invoiced).toLocaleString('en-GB', { minimumFractionDigits: 2 });
      return `£${n} across ${f.n_invoices} invoices` + (f.last_invoice_date ? ` · last ${String(f.last_invoice_date).slice(0,10)}` : '');
    },
  };
}
</script>
</body>
</html>
```

- [ ] **Step 3: Build, recreate, smoke-test the page**

```bash
cd /home_ai && python3 -m py_compile services/build-dashboard/main.py && echo COMPILE_OK
docker compose build build-dashboard && docker compose up -d --no-deps build-dashboard
sleep 5
echo "--- page route returns the HTML ---"
curl -s http://100.104.82.53:8090/app/memory | grep -c 'Cultural memory'
echo "--- the page's two data calls work (owner) ---"
curl -s -o /dev/null -w "list=%{http_code} " -H 'X-Realm: owner' "http://100.104.82.53:8090/api/memory/counterparties?limit=1"
curl -s -o /dev/null -w "detail=%{http_code}\n" -H 'X-Realm: owner' "http://100.104.82.53:8090/api/memory/counterparty/641"
```
Expected: `COMPILE_OK`, the grep prints `>=1` (title present), `list=200 detail=200`.

- [ ] **Step 4: Commit**

```bash
git add services/build-dashboard/main.py services/build-dashboard/static/memory.html
git commit -m "U242 P3: /app/memory browsable directory + dossier drawer"
```

---

### Task 4: Link from Mission Control (discoverability)

**Files:**
- Modify: `services/build-dashboard/static/index.html`

- [ ] **Step 1: Find where other section links live**

Run: `grep -n 'href="/coverage"\|href="/documents"\|href="/app/\|Mission Control' services/build-dashboard/static/index.html | head`
Use the result to locate the nav/links block.

- [ ] **Step 2: Add a link**

Add, alongside the existing page links in `index.html` (match the surrounding markup exactly — copy a neighbouring `<a>` and change href/text to):

```html
<a href="/app/memory" class="...copy classes from the neighbouring link...">Cultural memory</a>
```

- [ ] **Step 3: Rebuild + confirm**

```bash
cd /home_ai && docker compose build build-dashboard && docker compose up -d --no-deps build-dashboard
sleep 5; curl -s http://100.104.82.53:8090/ | grep -c '/app/memory'
```
Expected: `>=1`.

- [ ] **Step 4: Commit**

```bash
git add services/build-dashboard/static/index.html
git commit -m "U242 P3: link Cultural memory from Mission Control"
```

---

## Done criteria (P3)

- `/app/memory` loads: a searchable/filterable counterparty directory (Tabulator), ranked by signal; clicking a row opens the dossier drawer (summary, £ financials, people, open threads, citations); "Distil now" runs the lazy P2 endpoint and refreshes.
- Both GET APIs are owner-gated (work → 403), detail 404s on missing id.
- `/api/research/ask` and existing pages unaffected (additive routes only).

## Authelia note (surface to Jo — not done in code)

`/app/memory` and `/api/memory/*` must be restricted to the **owner** identity at the Authelia proxy (same tier as `/build`, `/admin`). The in-app 403 is defence-in-depth; the proxy ACL is the real gate. Confirm the access-control rules cover the `/app/memory` and `/api/memory` paths.

## Self-review notes (author)

- **Spec §6 coverage:** directory with search/filter/sort + dossier view (Task 3), list + detail APIs (Tasks 1-2), owner-only (all), Mission Control link (Task 4). Citations render as chips (`email #N`); deep-linking each to the emails browser is deferred (no stable per-email route confirmed) — noted, not invented.
- **Reuse:** mirrors `static/coverage.html` (Tailwind/Alpine/Tabulator) and reuses P2's `_decode_dossier` so jsonb fields arrive as objects.
- **Type consistency:** list rows expose `id, display_name, domain, email_count, linked_vendor, signal_score, has_dossier` — the page reads exactly these; detail returns `{counterparty, dossier}` — the drawer reads `selected.counterparty.*` and `selected.dossier.{summary,financials,people,open_threads,citations}`, matching P2's dossier schema.
- **No mass-distil:** the page only distils one counterparty at a time via the existing lazy endpoint (button); no batch trigger from the UI.
