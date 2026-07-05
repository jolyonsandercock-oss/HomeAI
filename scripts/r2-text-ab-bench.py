#!/usr/bin/env python3
"""r2-text-ab-bench.py — R2 text-model A/B: does qwen2.5:72b-instruct-q4_0 beat
gemma4-doc (the incumbent) at invoice LINE extraction enough to earn the
scheduled-sweep slot (u-invoice-line-sweep.sh)?

BENCHMARK ONLY. No writes to vendor_invoice_lines/vendor_invoice_inbox, no
pipeline changes. The prompt, JSON schema, cross-foot gate and every parsing
helper below are copied VERBATIM from scripts/invoice-line-extract.py so this
is an A/B of MODELS, not prompts — see that file's LINE_PROMPT_BASE,
parse_lines(), classify_doc(), parse_net_total(), profile_for(),
jr_department(), learned_example() (here reimplemented over `docker exec
psql`, host-side, matching scripts/r2-ocr-bench.py's style — no vault
credential needed, uses local trust auth into homeai-postgres).

Population: vendor_invoice_inbox rows with pdf_text_extracted already cached
AND classify_doc() says it's a real invoice AND a cross-foot target (net)
exists AND (zero rows in vendor_invoice_lines for that invoice OR the
existing lines fail the cross-foot gate). 50 sampled deterministically
(SQL setseed + vendor round-robin stratification), cached to sample.json so
re-invocations of either leg use the exact same docs/prompts.

Order: ALL gemma4-doc docs first, then ALL qwen2.5:72b docs (avoid GPU
load-thrash — 72b monopolises the 48GB card while loaded). keep_alive left
at ollama default so 72b evicts after the leg. 300s per-call timeout,
continue-on-error; a leg aborts if >20% of its first 10 docs error.

Usage:
  python3 scripts/r2-text-ab-bench.py                 # sample (if needed) + run both legs in order
  python3 scripts/r2-text-ab-bench.py --engine gemma   # just the gemma4-doc leg
  python3 scripts/r2-text-ab-bench.py --engine qwen72b # just the qwen leg
  python3 scripts/r2-text-ab-bench.py --resample       # force a fresh sample (overwrites sample.json)
  python3 scripts/r2-text-ab-bench.py --limit 5        # smoke-test on first 5 sample docs
"""
from __future__ import annotations

import argparse
import http.client
import json
import math
import re
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path("/home_ai")
OUT_DIR = REPO / "analysis" / "r2-text-ab"
SAMPLE_PATH = OUT_DIR / "sample.json"
RESULTS_JSONL = OUT_DIR / "results.jsonl"
RESULTS_MD = OUT_DIR / "RESULTS.md"

OLLAMA_URL = "http://localhost:11434/api/generate"
SEED = 0.42
N_SAMPLE = 50
CALL_TIMEOUT = 300

ENGINES = ["gemma4-doc:latest", "qwen2.5:72b-instruct-q4_0"]
ENGINE_KEYS = {"gemma4-doc:latest": "gemma", "qwen2.5:72b-instruct-q4_0": "qwen72b"}

_TRANSIENT_EXC = (urllib.error.URLError, ConnectionResetError, TimeoutError,
                   http.client.HTTPException, OSError)

# ── verbatim from scripts/invoice-line-extract.py ──────────────────────────
SUPPLIER_PROFILES = [
    (r'austell', 'bar',
     "St Austell Brewery (DRINKS, all 'bar' dept). Columns: Code, Description, Quantity, "
     "Gross Price, Discount, Net Price, EPR, Line Value, VAT%. line_net = the 'Line Value' column "
     "(NOT Gross/Net unit price). Items are kegs (50LTR), cases (6x75cl/24x...), wine."),
    (r'j ?& ?r|jr food', None,
     "J&R Foodservice (grocery). Lines are grouped under section headers FROZEN/CHILLED/AMBIENT/"
     "NON FOOD — put that header in 'category'. Columns: Code, Description (trailing dots), Qty, "
     "Unit (pack like 1x2.5kg), Unit Price, Value, VAT code. line_net = the 'Value' column. "
     "A description may wrap onto the next line — join it."),
    (r'forest', 'kitchen', "Forest Produce (fresh produce, pub kitchen). Often priced by weight/each."),
    (r'dole', 'kitchen', "Dole Foodservice (produce, pub kitchen)."),
    (r'kingfisher', 'kitchen', "Kingfisher Brixham (fresh fish/seafood, pub kitchen). Often priced per Kg."),
    (r'bidfresh|bidfood', 'kitchen', "Bidfresh/Bidfood (foodservice, pub kitchen)."),
    (r'westcountry', 'kitchen', "Westcountry Fruit Sales (fresh produce, pub kitchen)."),
    (r'totalproduce|total produce', 'kitchen', "Total Produce (fresh produce, pub kitchen)."),
    (r'tintagel brewing', 'bar', "Tintagel Brewing Co (local beer/ale → bar)."),
]


def profile_for(vendor_name):
    for pat, dept, hint in SUPPLIER_PROFILES:
        if re.search(pat, vendor_name or '', re.I):
            return dept, hint
    return None, ''


LINE_PROMPT_BASE = (
    "You are extracting LINE ITEMS from a UK supplier invoice. Return ONLY a JSON object "
    "{\"lines\":[...]}, no prose. Each line: {\"code\":string, \"description\":string, "
    "\"qty\":number, \"unit\":string, \"unit_price\":number, \"line_net\":number, \"category\":string}. "
    "line_net is the line VALUE (the extended amount for that row), NOT the unit price. "
    "Include EVERY product row across ALL pages; the invoice may be multi-page — IGNORE repeated "
    "column headers, page numbers, 'continued', addresses, and the VAT/totals summary block. "
    "Numbers plain (no symbols).")


def parse_lines(resp):
    if not resp:
        return []
    try:
        j = json.loads(resp)
    except Exception:
        m = re.search(r'\[.*\]', resp, re.S)
        if not m:
            return []
        try:
            j = json.loads(m.group(0))
        except Exception:
            return []
    if isinstance(j, dict):
        for v in j.values():
            if isinstance(v, list):
                j = v
                break
        else:
            j = []
    out = []
    for it in (j if isinstance(j, list) else []):
        if not isinstance(it, dict):
            continue

        def num(x):
            try:
                return float(str(x).replace(',', '').replace('£', '').strip())
            except Exception:
                return None
        out.append({'code': str(it.get('code', '') or '')[:40], 'description': str(it.get('description', '') or '')[:300],
                    'qty': num(it.get('qty')), 'unit': str(it.get('unit', '') or '')[:30],
                    'unit_price': num(it.get('unit_price')), 'line_net': num(it.get('line_net')),
                    'category': str(it.get('category', '') or '')[:40]})
    return out


def classify_doc(text):
    t = (text or '').lower()
    has_table = bool(re.search(r'\b(qty|quantity)\b.{0,30}\b(price|value|amount|each)\b', t)) \
        or bool(re.search(r'unit price|net price|line value|goods total', t))
    if re.search(r'remittance', t):
        return 'remittance', False
    if re.search(r's\s*t\s*a\s*t\s*e\s*m\s*e\s*n\s*t', t) and not has_table:
        return 'statement', False
    if re.search(r'statement of account|aged (debt|balance|creditor)|balance brought forward|amount overdue|in arrears', t):
        return 'statement', False
    if re.search(r'\binvoice no\b.{0,40}\bbalance\b', t, re.S) and not has_table:
        return 'statement', False
    if re.search(r'\bcurrent\b.{0,20}\b30\b.{0,20}\b60\b.{0,20}\b90\b', t):
        return 'statement', False
    if re.search(r'\b(final notice|payment reminder|reminder notice|overdue|please remit)\b', t) and not has_table:
        return 'chaser', False
    if has_table:
        return 'invoice', True
    if re.search(r'\binvoice\b', t) and len(re.findall(r'\d+\.\d{2}', text or '')) >= 3:
        return 'invoice?', True
    return 'other', False


def jr_department(text):
    if re.search(r'\bTOM106\b', text):
        return 'kitchen'
    if re.search(r'\bMAL125\b', text):
        return 'cafe'
    return None


def parse_net_total(text):
    pats = [r'Total\s+Exc\.?\s*VAT[^\d]{0,6}([\d,]+\.\d{2})',
            r'([\d,]+\.\d{2})\s*Ex(?:c)?\.?\s*VAT\b',
            r'(?:Goods|Net|Sub)[\s-]*Total[^\d]{0,6}([\d,]+\.\d{2})',
            r'Total\s+Net[^\d]{0,6}([\d,]+\.\d{2})']
    for p in pats:
        m = re.search(p, text, re.I)
        if m:
            try:
                return round(float(m.group(1).replace(',', '')), 2)
            except Exception:
                pass
    return None


def _vendor_key(vendor_name):
    return re.sub(r'[^a-z0-9]', '', (vendor_name or '').split('<')[0].lower())[:10]


def cross_foot_ok(foot, net):
    """Mirrors invoice-line-extract.py's own conf>=0.95 gate exactly:
    conf = 0.95 if (net and abs(foot - net) <= max(0.05, net * 0.02)) else lower."""
    if net is None:
        return False
    return abs(foot - net) <= max(0.05, net * 0.02)


# ── psql helpers (docker exec, matches r2-ocr-bench.py style — trust auth,
# no Vault credential needed) ────────────────────────────────────────────
def run_psql(statements: list[str], timeout: int = 120) -> str:
    cmd = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai", "-tA"]
    for s in statements:
        cmd += ["-c", s]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"psql failed rc={r.returncode}: {r.stderr[:400]}")
    return r.stdout


def psql_json(statements: list[str], timeout: int = 120):
    out = run_psql(statements, timeout=timeout)
    idx = None
    for ch in ("[", "{"):
        i = out.find(ch)
        if i != -1 and (idx is None or i < idx):
            idx = i
    if idx is None:
        return None
    return json.loads(out[idx:])


def esc(s: str) -> str:
    return (s or "").replace("'", "''")


def learned_example(vendor_name, vendor_domain, exclude_id):
    """Reimplementation of invoice-line-extract.py's learned_example() over psql
    instead of asyncpg. Same query/semantics: most recent >=0.92-confidence
    line-set from the same supplier, excluding the invoice itself. This reads
    PRODUCTION data (real prior extractions) — identical regardless of which
    engine is under test, so it's a fair, frozen prompt input for both legs."""
    if vendor_domain and len(vendor_domain) >= 4 and not re.search(r'intuit|xero|sage|quickbooks', vendor_domain, re.I):
        cond = f"v.vendor_domain = '{esc(vendor_domain)}'"
    else:
        key = _vendor_key(vendor_name)
        if len(key) < 5:
            return None
        cond = f"regexp_replace(lower(split_part(v.vendor_name,'<',1)),'[^a-z0-9]','','g') LIKE '{esc(key)}%'"
    sql = f"""
      SELECT json_agg(json_build_object('description',description,'qty',qty,'unit',unit,
             'unit_price',unit_price,'line_net',line_net) ORDER BY line_no) AS lines
        FROM vendor_invoice_lines
       WHERE invoice_id = (
         SELECT l2.invoice_id FROM vendor_invoice_lines l2
         JOIN vendor_invoice_inbox v ON v.id = l2.invoice_id
        WHERE {cond} AND l2.extraction_confidence >= 0.92 AND l2.invoice_id <> {int(exclude_id)}
        ORDER BY l2.invoice_id DESC LIMIT 1);"""
    try:
        res = psql_json(["SET app.current_entity='all';", sql])
    except Exception:
        return None
    if isinstance(res, list) and res and res[0].get('lines'):
        return res[0]['lines']
    if isinstance(res, dict):
        return res.get('lines')
    return None


def build_prompt(vendor_name, learned_lines, text):
    prof_dept, hint = profile_for(vendor_name)
    if learned_lines:
        primed = (f"\n\nLEARNED EXAMPLE — invoices from this supplier have previously extracted as the "
                  f"following line shape; match it EXACTLY (same columns, same granularity, one row per product):\n"
                  f"{json.dumps(learned_lines)[:1800]}")
    else:
        primed = (f"\n\nSupplier layout note: {hint}" if hint else '')
    return LINE_PROMPT_BASE + primed + "\n\n---\n" + text[:6000]


# ── sampling ────────────────────────────────────────────────────────────
def build_sample():
    print("sampling population (setseed shuffle, then vendor round-robin stratify)...")
    rows = psql_json([
        f"SELECT setseed({SEED});",
        """SELECT json_agg(t) FROM (
             SELECT v.id, v.vendor_name, v.vendor_domain, v.pdf_text_extracted AS text,
                    v.net_amount, v.gross_amount,
                    (SELECT SUM(l.line_net) FROM vendor_invoice_lines l WHERE l.invoice_id = v.id) AS existing_foot
               FROM vendor_invoice_inbox v
              WHERE v.pdf_text_extracted IS NOT NULL AND length(v.pdf_text_extracted) > 50
                AND v.source_email_id IS NOT NULL
              ORDER BY random() LIMIT 2500
           ) t;"""
    ], timeout=60)
    print(f"  fetched {len(rows)} shuffled candidates from DB")

    qualified = []
    for r in rows:
        text = r.get("text") or ""
        net = parse_net_total(text)
        if net is None:
            net = float(r["net_amount"]) if r.get("net_amount") is not None else (
                float(r["gross_amount"]) if r.get("gross_amount") is not None else None)
        if net is None:
            continue
        doc_type, looks_invoice = classify_doc(text)
        if not looks_invoice:
            continue
        foot = r.get("existing_foot")
        zero_lines = foot is None
        fails_crossfoot = (not zero_lines) and not cross_foot_ok(float(foot), net)
        if not (zero_lines or fails_crossfoot):
            continue  # already has lines AND they cross-foot fine — not part of the failure population
        qualified.append({**r, "_target_net": net, "_zero_lines": zero_lines})
    print(f"  {len(qualified)} qualify (invoice-shaped, has cross-foot target, zero-lines-or-failing)")

    # vendor round-robin stratification (already-shuffled order preserved within each bucket)
    buckets: dict[str, list] = {}
    for r in qualified:
        buckets.setdefault(r.get("vendor_name") or "?", []).append(r)
    vendor_order = list(buckets.keys())  # preserves shuffle order of first-seen
    picked = []
    idx = 0
    while len(picked) < N_SAMPLE and any(buckets.values()):
        vname = vendor_order[idx % len(vendor_order)]
        if buckets[vname]:
            picked.append(buckets[vname].pop(0))
        idx += 1
        if idx > 100000:
            break

    sample = []
    for r in picked:
        learned = learned_example(r.get("vendor_name"), r.get("vendor_domain"), r["id"])
        sample.append({
            "id": r["id"], "vendor_name": r.get("vendor_name"), "vendor_domain": r.get("vendor_domain"),
            "text": r["text"], "target_net": r["_target_net"], "zero_lines": r["_zero_lines"],
            "existing_foot": float(r["existing_foot"]) if r.get("existing_foot") is not None else None,
            "learned_example": learned,
        })
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    SAMPLE_PATH.write_text(json.dumps(sample, indent=1))
    n_vendors = len({s["vendor_name"] for s in sample})
    n_zero = sum(1 for s in sample if s["zero_lines"])
    print(f"  wrote {len(sample)} docs ({n_vendors} distinct vendors, {n_zero} zero-lines / "
          f"{len(sample) - n_zero} failing-cross-foot) -> {SAMPLE_PATH}")
    return sample


def load_sample(resample=False):
    if not resample and SAMPLE_PATH.exists():
        return json.loads(SAMPLE_PATH.read_text())
    return build_sample()


# ── ollama call ─────────────────────────────────────────────────────────
def ollama_generate(model, prompt):
    """Returns (response_text_or_None, latency_s, error_or_None). think:false is
    REQUIRED for gemma4-doc (a thinking model) — without it the thinking channel
    eats the budget and /api/generate returns an empty response (known trap,
    see invoice-line-extract.py). keep_alive is left at ollama's default so a
    41GB 72b model evicts after this leg instead of pinning the GPU."""
    body = json.dumps({
        "model": model, "prompt": prompt, "stream": False,
        "think": False, "format": "json", "options": {"temperature": 0},
    }).encode()
    req = urllib.request.Request(OLLAMA_URL, data=body, method="POST",
                                  headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    try:
        resp = json.loads(urllib.request.urlopen(req, timeout=CALL_TIMEOUT).read())
        dt = time.monotonic() - t0
        return resp.get("response", ""), dt, None
    except urllib.error.HTTPError as e:
        dt = time.monotonic() - t0
        return None, dt, f"HTTP {e.code}: {e.read()[:200]!r}"
    except _TRANSIENT_EXC as e:
        dt = time.monotonic() - t0
        return None, dt, f"transient: {e}"
    except Exception as e:
        dt = time.monotonic() - t0
        return None, dt, f"error: {e}"


# ── JSONL persistence ───────────────────────────────────────────────────
def append_jsonl(row: dict):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with open(RESULTS_JSONL, "a") as f:
        f.write(json.dumps(row) + "\n")


def read_jsonl() -> list[dict]:
    if not RESULTS_JSONL.exists():
        return []
    out = []
    for line in RESULTS_JSONL.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def percentile(values, p):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * p
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return s[int(k)]
    return s[f] + (s[c] - s[f]) * (k - f)


# ── per-engine leg ──────────────────────────────────────────────────────
def run_leg(engine: str, sample: list[dict], limit: int | None = None):
    key = ENGINE_KEYS[engine]
    done_ids = {r["id"] for r in read_jsonl() if r.get("engine") == engine}
    docs = sample if limit is None else sample[:limit]
    todo = [d for d in docs if d["id"] not in done_ids]
    if not todo:
        print(f"[{key}] nothing to do ({len(done_ids)} already recorded)")
        return
    print(f"[{key}] running {len(todo)} docs (model={engine}) ...")
    errors_first10 = 0
    aborted = False
    for i, d in enumerate(todo, 1):
        prompt = build_prompt(d["vendor_name"], d.get("learned_example"), d["text"])
        resp, dt, err = ollama_generate(engine, prompt)
        rec = {"engine": engine, "id": d["id"], "vendor_name": d.get("vendor_name"), "latency_s": round(dt, 2)}
        if err:
            rec.update({"accepted": False, "error": err, "parse_failure": None})
        else:
            lines = parse_lines(resp)
            foot = sum(l["line_net"] for l in lines if l["line_net"] is not None) if lines else 0.0
            parse_failure = len(lines) == 0
            accepted = (not parse_failure) and cross_foot_ok(foot, d["target_net"])
            rec.update({"accepted": accepted, "error": None, "parse_failure": parse_failure,
                        "n_lines": len(lines), "foot": round(foot, 2), "target_net": d["target_net"]})
        append_jsonl(rec)
        if i <= 10 and err:
            errors_first10 += 1
        if i % 10 == 0:
            print(f"  [{key}] ...{i}/{len(todo)} done", flush=True)
        if i == 10 and errors_first10 > 2:
            print(f"[{key}] ABORTING leg — {errors_first10}/10 errors in the first 10 docs (>20%)")
            aborted = True
            break
    if not aborted:
        print(f"[{key}] leg complete ({len(todo)} docs)")


# ── RESULTS.md ──────────────────────────────────────────────────────────
def render_results_md():
    rows = read_jsonl()
    lines = [
        "# R2 text-model A/B — invoice LINE extraction — Results",
        "",
        f"gemma4-doc:latest (incumbent, think:false) vs qwen2.5:72b-instruct-q4_0 (candidate), "
        f"n={N_SAMPLE} sampled invoices (seed={SEED}). Prompt/schema/cross-foot gate copied "
        f"verbatim from scripts/invoice-line-extract.py — this is an A/B of MODELS only.",
        "",
        "| engine | n run | accepted | accept% | parse-fail | errors | median s | p90 s |",
        "|---|---|---|---|---|---|---|---|",
    ]
    summary = {}
    for engine in ENGINES:
        erows = [r for r in rows if r["engine"] == engine]
        n = len(erows)
        accepted = sum(1 for r in erows if r.get("accepted"))
        parse_fail = sum(1 for r in erows if r.get("parse_failure"))
        errors = sum(1 for r in erows if r.get("error"))
        ok_rows = [r for r in erows if not r.get("error")]
        lat = [r["latency_s"] for r in ok_rows]
        med = percentile(lat, 0.5)
        p90 = percentile(lat, 0.9)
        pct = f"{100*accepted/n:.0f}%" if n else "–"
        med_s = f"{med:.1f}s" if med is not None else "–"
        p90_s = f"{p90:.1f}s" if p90 is not None else "–"
        lines.append(f"| {engine} | {n} | {accepted} | {pct} | {parse_fail} | {errors} | {med_s} | {p90_s} |")
        summary[engine] = {"n": n, "accepted": accepted, "parse_fail": parse_fail,
                            "errors": errors, "median_s": med, "p90_s": p90}
    lines.append("")

    qwen = summary.get("qwen2.5:72b-instruct-q4_0", {})
    if qwen.get("median_s") is not None:
        med, p90 = qwen["median_s"], qwen["p90_s"]
        lines.append(
            f"## Extrapolated nightly 50-doc sweep at qwen2.5:72b speed\n\n"
            f"- at median ({med:.1f}s/doc): {med*50/60:.1f} min ({med*50/3600:.2f} h)\n"
            f"- at p90 ({p90:.1f}s/doc, conservative): {p90*50/60:.1f} min ({p90*50/3600:.2f} h)\n"
        )
    lines.append(f"_Generated {time.strftime('%Y-%m-%d %H:%M:%S')}_")
    RESULTS_MD.write_text("\n".join(lines) + "\n")
    print(f"RESULTS.md written -> {RESULTS_MD}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", choices=["gemma", "qwen72b", "all"], default="all")
    ap.add_argument("--resample", action="store_true")
    ap.add_argument("--limit", type=int, default=None, help="only run the first N sample docs (smoke test)")
    args = ap.parse_args()

    sample = load_sample(resample=args.resample)
    print(f"sample size: {len(sample)}")

    order = ENGINES if args.engine == "all" else (
        [ENGINES[0]] if args.engine == "gemma" else [ENGINES[1]])
    for engine in order:
        run_leg(engine, sample, limit=args.limit)
        render_results_md()
    render_results_md()
    print("\n── bench complete ──")


if __name__ == "__main__":
    main()
