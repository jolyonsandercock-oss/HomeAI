#!/usr/bin/env python3
"""r2-ocr-bench.py — R2 OCR/vision engine bake-off.

Scores local vision models (qwen2.5vl:7b baseline, gemma4-qat31b, qwen2.5vl:32b)
plus a Mistral-OCR-then-local-text-extraction leg, on real invoice PDFs, to decide
whether the resident vision model should change and whether a supplier
learned-example few-shot helps. Pluggable engine registry (ENGINES below) — a new
engine is a new entry + a run_<kind>() implementation, nothing else changes.

Two evaluation sets, sampled once and cached (reproducible across re-invocations
of individual --engine/--set legs):
  SET A — extraction_method='pdf' rows with valid net+vat=gross arithmetic,
          vendor_name + invoice_date present, PDF on disk. Ground truth = the
          text-layer-derived amounts. ~100 sampled.
  SET B — extraction_method='pdf_low_conf', no text layer, no amount yet
          (u281's own hard set). No ground truth; scored by gate() acceptance.

GPU discipline (live system): engines run strictly serially, never two large
vision models interleaved. A trivial qwen2.5:7b generate (num_predict=1) is
fired every ~10 docs and at every engine-segment boundary to keep the
production classify path warm. All ollama/vault calls retry on 429/503/5xx
with backoff and never hammer a wedged service.

Standalone stdlib-only, matching scripts/u276-vision-ocr-bench.py's style
(urllib + docker exec psql, no third-party deps).

Usage:
  python3 scripts/r2-ocr-bench.py --engine all --set all
  python3 scripts/r2-ocr-bench.py --engine qwen32b --set B
  python3 scripts/r2-ocr-bench.py --engine mistral_text --set A
"""
from __future__ import annotations

import argparse
import base64
import http.client
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

# Transient/retryable low-level exceptions — separate from urllib.error.HTTPError
# (which carries a status code we inspect explicitly). Seen in practice tonight:
# a concurrent `ollama pull` saturating disk/net caused ECONNRESET on /api/generate
# even though the server itself was healthy.
_TRANSIENT_EXC = (urllib.error.URLError, ConnectionResetError, TimeoutError,
                   http.client.HTTPException, OSError)

REPO = Path("/home_ai")
OUT_DIR = REPO / "analysis" / "r2-ocr-bench"
RESULTS_MD = OUT_DIR / "RESULTS.md"
STATUS_JSON = OUT_DIR / "status.json"
SAMPLE_A = OUT_DIR / "sample_setA.json"
SAMPLE_B = OUT_DIR / "sample_setB.json"

RENDER_URL = "http://localhost:8003/render-page1-png?width=1400"
OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_TAGS_URL = "http://localhost:11434/api/tags"
WARM_MODEL = "qwen2.5:7b"

SEED = 0.42
N_A = 100
N_B = 80

VISION_PROMPT = (
    "This is an invoice. Read it carefully and return ONLY a JSON object, no other text:\n"
    '{"vendor": "<supplier name>", "invoice_number": "<number or null>", '
    '"invoice_date": "<YYYY-MM-DD or null>", "net": <number or null>, '
    '"vat": <number or null>, "gross": <number or null>}\n'
    "gross is the total amount payable including VAT. Use null for anything not visible."
)

TEXT_PROMPT_TMPL = (
    "Below is OCR text extracted from an invoice. Read it carefully and return ONLY a "
    "JSON object, no other text:\n"
    '{"vendor": "<supplier name>", "invoice_number": "<number or null>", '
    '"invoice_date": "<YYYY-MM-DD or null>", "net": <number or null>, '
    '"vat": <number or null>, "gross": <number or null>}\n'
    "gross is the total amount payable including VAT. Use null for anything not present.\n\n"
    "OCR TEXT:\n{text}\n"
)

# ── engine registry (pluggable) ─────────────────────────────────────────────
# kind: 'vision' (ollama /api/generate with images) or 'mistral_text'
# (Mistral OCR API -> markdown -> qwen2.5:7b text extraction).
ENGINES = {
    "qwen7b":          {"label": "qwen2.5vl:7b",              "kind": "vision", "model": "qwen2.5vl:7b",    "learned": False},
    "qwen7b_learned":  {"label": "qwen2.5vl:7b+learned",       "kind": "vision", "model": "qwen2.5vl:7b",    "learned": True},
    "gemma31b":        {"label": "gemma4-qat31b",              "kind": "vision", "model": "gemma4-qat31b",   "learned": False},
    "gemma31b_learned":{"label": "gemma4-qat31b+learned",      "kind": "vision", "model": "gemma4-qat31b",   "learned": True},
    "qwen32b":         {"label": "qwen2.5vl:32b",              "kind": "vision", "model": "qwen2.5vl:32b",   "learned": False},
    "qwen32b_learned": {"label": "qwen2.5vl:32b+learned",      "kind": "vision", "model": "qwen2.5vl:32b",   "learned": True},
    "mistral_text":    {"label": "mistral_ocr+text(qwen2.5:7b)","kind": "mistral_text", "model": None,      "learned": False},
}
# Serial run order for --engine all (never two large vision models interleaved).
RUN_ORDER = ["qwen7b", "qwen7b_learned", "gemma31b", "gemma31b_learned",
             "qwen32b", "qwen32b_learned", "mistral_text"]


# ── psql helpers (docker exec, matches u276/u281 style) ────────────────────
def run_psql(statements: list[str], timeout: int = 60) -> str:
    cmd = ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai", "-tA"]
    for s in statements:
        cmd += ["-c", s]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"psql failed rc={r.returncode}: {r.stderr[:400]}")
    return r.stdout


def psql_json(statements: list[str], timeout: int = 60):
    """Run statements in one session; last statement must SELECT a json_agg/json_build_object.
    Parses from the first '[' or '{' to end of stdout (robust to json_agg's embedded
    newlines/whitespace, which JSON parsing tolerates outside of quoted strings)."""
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


# ── sample selection (seeded, cached for reproducibility across re-runs) ───
def load_or_sample(cache_path: Path, n: int, query: str) -> list[dict]:
    if cache_path.exists():
        return json.loads(cache_path.read_text())
    rows = psql_json([
        "SET app.current_entity='all';",
        f"SELECT setseed({SEED});",
        query.format(n=n),
    ], timeout=120) or []
    cache_path.write_text(json.dumps(rows, indent=1))
    print(f"  sampled {len(rows)} rows -> {cache_path.name}")
    return rows


def get_set_a() -> list[dict]:
    q = """
      SELECT json_agg(t) FROM (
        SELECT id, pdf_local_path, vendor_name, vendor_domain,
               invoice_date::text AS invoice_date, net_amount, vat_amount, gross_amount
          FROM vendor_invoice_inbox
         WHERE extraction_method='pdf'
           AND net_amount IS NOT NULL AND vat_amount IS NOT NULL AND gross_amount IS NOT NULL
           AND abs((net_amount+vat_amount)-gross_amount) <= 0.02
           AND vendor_name IS NOT NULL AND invoice_date IS NOT NULL
           AND pdf_local_path IS NOT NULL
         ORDER BY random() LIMIT {n}
      ) t;"""
    rows = load_or_sample(SAMPLE_A, N_A, q)
    return [r for r in rows if os.path.exists(r["pdf_local_path"])]


def get_set_b() -> list[dict]:
    q = """
      SELECT json_agg(t) FROM (
        SELECT id, pdf_local_path, vendor_name, vendor_domain
          FROM vendor_invoice_inbox
         WHERE extraction_method='pdf_low_conf'
           AND (pdf_text_extracted IS NULL OR pdf_text_extracted='')
           AND pdf_local_path IS NOT NULL
           AND coalesce(gross_amount,0)=0
           AND coalesce(is_statement,false)=false
         ORDER BY random() LIMIT {n}
      ) t;"""
    rows = load_or_sample(SAMPLE_B, N_B, q)
    return [r for r in rows if os.path.exists(r["pdf_local_path"])]


# ── learned-example (supplier few-shot), mirrors invoice-line-extract.py ───
def _vendor_key(vendor_name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (vendor_name or "").split("<")[0].lower())[:10]


def get_learned_example(vendor_name: str, vendor_domain: str, exclude_id: int):
    if vendor_domain and len(vendor_domain) >= 4 and not re.search(r"intuit|xero|sage|quickbooks", vendor_domain, re.I):
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
    return res


def build_learned_prompt(lines) -> str:
    if not lines:
        return VISION_PROMPT
    exemplar = json.dumps(lines, ensure_ascii=False)
    if len(exemplar) > 1800:
        exemplar = exemplar[:1800] + "...(truncated)"
    prefix = (
        "Reference only — a previously verified correct line-extraction from an "
        "earlier invoice by the SAME supplier, showing this supplier's typical layout:\n"
        f"{exemplar}\n\n"
        "Now extract THIS invoice's own values (do not copy the reference numbers):\n"
    )
    return prefix + VISION_PROMPT


# ── ollama / render calls ───────────────────────────────────────────────────
def render_png(pdf_path: str, page: int = 0) -> tuple[bytes, int]:
    with open(pdf_path, "rb") as f:
        body = f.read()
    boundary = "----r2bench"
    payload = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"doc.pdf\"\r\nContent-Type: application/pdf\r\n\r\n"
    ).encode() + body + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{RENDER_URL}&page={page}", data=payload, method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    last_err = None
    for attempt in range(3):
        try:
            resp = urllib.request.urlopen(req, timeout=60)
            return resp.read(), int(resp.headers.get("X-Page-Count", "1"))
        except _TRANSIENT_EXC as e:
            last_err = e
            if attempt < 2:
                time.sleep(10 * (attempt + 1))
                continue
            raise
    raise RuntimeError(f"render_png: exhausted retries: {last_err}")


def _ollama_generate(payload: dict, retries: int = 3) -> dict:
    req = urllib.request.Request(OLLAMA_URL, method="POST", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    last_err = None
    for attempt in range(retries):
        try:
            return json.loads(urllib.request.urlopen(req, timeout=300).read())
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code in (429, 500, 502, 503, 504, 529) and attempt < retries - 1:
                time.sleep(30 * (attempt + 1))
                continue
            raise
        except _TRANSIENT_EXC as e:
            # e.g. ECONNRESET from a concurrent `ollama pull` saturating the host —
            # transient, not a model/prompt failure. Back off and retry.
            last_err = e
            if attempt < retries - 1:
                time.sleep(10 * (attempt + 1))
                continue
            raise
    raise RuntimeError(f"ollama generate: exhausted retries: {last_err}")


def _parse_json_response(raw: str) -> dict:
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        raw = raw[4:] if raw.lower().startswith("json") else raw
    try:
        start, end = raw.index("{"), raw.rindex("}") + 1
        return json.loads(raw[start:end])
    except Exception:
        return {"_parse_error": raw[:200]}


def vision_extract(model: str, png: bytes, prompt: str) -> tuple[dict, float]:
    t0 = time.monotonic()
    resp = _ollama_generate({
        "model": model, "prompt": prompt, "images": [base64.b64encode(png).decode()],
        "stream": False, "options": {"temperature": 0, "num_predict": 300},
    })
    dt = time.monotonic() - t0
    return _parse_json_response(resp.get("response", "")), dt


def text_extract(model: str, prompt: str) -> tuple[dict, float]:
    t0 = time.monotonic()
    resp = _ollama_generate({
        "model": model, "prompt": prompt, "stream": False,
        "options": {"temperature": 0, "num_predict": 300},
    })
    dt = time.monotonic() - t0
    return _parse_json_response(resp.get("response", "")), dt


def extract_document_vision(pdf_path: str, model: str, prompt: str, max_pages: int = 3):
    """Back-to-front page scan (totals live on the last page); returns (fields, dt, pages_tried)."""
    png0, n_pages = render_png(pdf_path, 0)
    total_dt = 0.0
    tried = 0
    first_result: dict = {}
    order = list(range(n_pages - 1, -1, -1))[:max_pages]
    if 0 not in order:
        order.append(0)
    for p in order:
        png = png0 if p == 0 else render_png(pdf_path, p)[0]
        res, dt = vision_extract(model, png, prompt)
        total_dt += dt
        tried += 1
        if not first_result:
            first_result = res
        if isinstance(res.get("gross"), (int, float)):
            return res, total_dt, tried
    return first_result, total_dt, tried


def keepalive_ping() -> bool:
    for attempt in range(3):
        try:
            _ollama_generate({"model": WARM_MODEL, "prompt": "ping", "stream": False,
                               "options": {"temperature": 0, "num_predict": 1}}, retries=1)
            return True
        except urllib.error.HTTPError as e:
            if e.code == 503 and attempt < 2:
                time.sleep(30)
                continue
            return False
        except Exception:
            return False
    return False


def ollama_model_names() -> list[str]:
    try:
        with urllib.request.urlopen(OLLAMA_TAGS_URL, timeout=10) as r:
            d = json.loads(r.read())
        return [m["name"] for m in d.get("models", [])]
    except Exception:
        return []


def poll_for_model(model: str, poll_interval: int = 60, max_wait: int = 4 * 3600) -> bool:
    start = time.monotonic()
    n = 0
    while True:
        names = ollama_model_names()
        if any(name == model or name.startswith(model + ":") or name == f"{model}:latest" for name in names):
            return True
        elapsed = time.monotonic() - start
        if elapsed > max_wait:
            print(f"[wait] {model} still absent after {int(elapsed)}s — giving up")
            return False
        if n % 5 == 0:
            print(f"[wait] {model} not yet present (waited {int(elapsed)}s) — polling every {poll_interval}s")
        n += 1
        time.sleep(poll_interval)


def smoke_test_vision(model: str, sample_pdf: str) -> tuple[bool, str]:
    """One real-invoice call; must return parseable JSON with at least one non-null
    field to count as vision-capable."""
    try:
        png, _ = render_png(sample_pdf, 0)
        res, dt = vision_extract(model, png, VISION_PROMPT)
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}: {e.read()[:150]!r}"
    except Exception as e:
        return False, f"error: {str(e)[:150]}"
    if "_parse_error" in res:
        return False, f"non-JSON response: {res['_parse_error'][:120]!r}"
    if not any(res.get(k) is not None for k in ("vendor", "gross", "net", "invoice_number")):
        return False, f"all fields null: {res}"
    return True, f"ok ({dt:.1f}s, sample fields: gross={res.get('gross')} vendor={res.get('vendor')})"


# ── mistral OCR + local text extraction leg ────────────────────────────────
def resolve_vault_env() -> tuple[str, str] | None:
    try:
        out = subprocess.run(
            ["docker", "inspect", "-f",
             "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", "homeai-vault"],
            capture_output=True, text=True, timeout=10).stdout.strip()
        vip = out.split()[0] if out.split() else None
        if not vip:
            return None
        vault_addr = f"http://{vip}:8200"
    except Exception:
        return None
    token = None
    env_path = REPO / ".env"
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if line.startswith("VAULT_TOKEN="):
                token = line.split("=", 1)[1].strip().strip('"').strip("'")
                break
    if not token:
        return None
    return vault_addr, token


def make_mistral_adapter():
    resolved = resolve_vault_env()
    if not resolved:
        return None, "vault addr/token unresolved"
    vault_addr, token = resolved
    sys.path.insert(0, str(REPO / "scripts"))
    try:
        from ocr.mistral_ocr import MistralOCRAdapter, _HTTPVaultClient  # noqa: E402
    except Exception as e:
        return None, f"import failed: {e}"
    adapter = MistralOCRAdapter.from_vault(_HTTPVaultClient(addr=vault_addr, token=token))
    if adapter is None:
        return None, "no secret/mistral-ocr in vault (or vault unreachable)"
    return adapter, "ok"


def mistral_extract_document(adapter, pdf_path: str) -> tuple[dict, float, float, int]:
    """Returns (fields, mistral_latency_s, extract_latency_s, page_count)."""
    from pathlib import Path as _Path
    t0 = time.monotonic()
    result = adapter.extract(_Path(pdf_path), doc_kind="invoice")
    mistral_dt = time.monotonic() - t0
    page_count = len(result.raw.get("pages") or [])
    text = result.text[:8000]
    # .replace, not .format — the template's JSON example braces make
    # str.format raise KeyError('"vendor"') (killed all 180 docs on the first run)
    fields, extract_dt = text_extract(WARM_MODEL, TEXT_PROMPT_TMPL.replace("{text}", text))
    return fields, mistral_dt, extract_dt, page_count


# ── scoring ──────────────────────────────────────────────────────────────
def gate(res: dict):
    g, n, v = res.get("gross"), res.get("net"), res.get("vat")
    if not isinstance(g, (int, float)) or not (0 < float(g) < 50000):
        return None
    if isinstance(n, (int, float)) and isinstance(v, (int, float)):
        if abs((float(n) + float(v)) - float(g)) <= 0.02:
            return round(float(n), 2), round(float(v), 2), round(float(g), 2)
        return None
    if isinstance(n, (int, float)) and v in (0, None) and abs(float(n) - float(g)) <= 0.02:
        return round(float(n), 2), 0.0, round(float(g), 2)
    return None


def parse_date_flexible(s):
    if not s or not isinstance(s, str):
        return None
    s = s.strip()
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", s)
    if m:
        try:
            return date(int(m[1]), int(m[2]), int(m[3])).isoformat()
        except ValueError:
            return None
    m = re.match(r"^(\d{1,2})/(\d{1,2})/(\d{2,4})$", s)
    if m:
        d_, mo, y = m.groups()
        y = ("20" + y) if len(y) == 2 else y
        try:
            return date(int(y), int(mo), int(d_)).isoformat()
        except ValueError:
            return None
    return None


def vendor_match(pred, truth, threshold: float = 0.8) -> bool:
    def norm_tokens(s):
        s = (s or "").split("<")[0]
        return set(re.findall(r"[a-z0-9]+", s.lower()))
    ta, tb = norm_tokens(pred), norm_tokens(truth)
    if not ta or not tb:
        return False
    return (len(ta & tb) / len(tb)) >= threshold


def num_match(pred, truth) -> bool:
    if not isinstance(pred, (int, float)) or truth is None:
        return False
    try:
        return abs(float(pred) - float(truth)) <= 0.02
    except (TypeError, ValueError):
        return False


def score_against_truth(fields: dict, truth_row: dict) -> dict:
    vendor_ok = vendor_match(fields.get("vendor"), truth_row.get("vendor_name"))
    pred_date = parse_date_flexible(fields.get("invoice_date"))
    date_ok = bool(pred_date and pred_date == truth_row.get("invoice_date"))
    net_ok = num_match(fields.get("net"), truth_row.get("net_amount"))
    vat_ok = num_match(fields.get("vat"), truth_row.get("vat_amount"))
    gross_ok = num_match(fields.get("gross"), truth_row.get("gross_amount"))
    return {
        "vendor_ok": vendor_ok, "date_ok": date_ok,
        "net_ok": net_ok, "vat_ok": vat_ok, "gross_ok": gross_ok,
        "all_ok": all([vendor_ok, date_ok, net_ok, vat_ok, gross_ok]),
    }


def percentile(values: list[float], p: float):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * p
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return s[int(k)]
    return s[f] + (s[c] - s[f]) * (k - f)


# ── JSONL persistence ───────────────────────────────────────────────────────
def jsonl_path(engine_key: str, set_name: str) -> Path:
    return OUT_DIR / f"{engine_key}_{set_name}.jsonl"


def append_jsonl(path: Path, row: dict):
    with open(path, "a") as f:
        f.write(json.dumps(row) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


# ── status tracking (skips, unavailability, notes) ──────────────────────────
def load_status() -> dict:
    if STATUS_JSON.exists():
        return json.loads(STATUS_JSON.read_text())
    return {}


def save_status(status: dict):
    STATUS_JSON.write_text(json.dumps(status, indent=1))


def set_status(engine_key: str, note: str):
    status = load_status()
    status[engine_key] = note
    save_status(status)


# ── RESULTS.md renderer ─────────────────────────────────────────────────────
def render_results_md():
    status = load_status()
    lines = [
        "# R2 OCR / Vision Engine Bake-off — Results",
        "",
        f"Seed={SEED}  SET A (ground-truth, n≈{N_A})  SET B (hard/no-truth, n≈{N_B})",
        "",
        "| engine | set | n | vendor% | date% | net% | vat% | gross% | all-fields% | gate-accept% | median s | p90 s | errors |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for engine_key in RUN_ORDER:
        label = ENGINES[engine_key]["label"]
        any_rows = False
        for set_name in ("A", "B"):
            path = jsonl_path(engine_key, set_name)
            rows = read_jsonl(path)
            if not rows:
                continue
            any_rows = True
            n = len(rows)
            errors = sum(1 for r in rows if r.get("error"))
            ok_rows = [r for r in rows if not r.get("error")]
            lat = [r["latency_s"] for r in ok_rows if isinstance(r.get("latency_s"), (int, float))]
            med = percentile(lat, 0.5)
            p90 = percentile(lat, 0.9)
            gate_n = sum(1 for r in ok_rows if r.get("gate_ok"))
            gate_pct = f"{100*gate_n/len(ok_rows):.0f}%" if ok_rows else "–"
            if set_name == "A":
                v = sum(1 for r in ok_rows if r.get("vendor_ok"))
                d = sum(1 for r in ok_rows if r.get("date_ok"))
                ne = sum(1 for r in ok_rows if r.get("net_ok"))
                va = sum(1 for r in ok_rows if r.get("vat_ok"))
                gr = sum(1 for r in ok_rows if r.get("gross_ok"))
                al = sum(1 for r in ok_rows if r.get("all_ok"))
                denom = len(ok_rows) or 1
                cols = [f"{100*v/denom:.0f}%", f"{100*d/denom:.0f}%", f"{100*ne/denom:.0f}%",
                        f"{100*va/denom:.0f}%", f"{100*gr/denom:.0f}%", f"{100*al/denom:.0f}%"]
            else:
                cols = ["–", "–", "–", "–", "–", "–"]
            med_s = f"{med:.1f}s" if med is not None else "–"
            p90_s = f"{p90:.1f}s" if p90 is not None else "–"
            lines.append(
                f"| {label} | {set_name} | {n} | {cols[0]} | {cols[1]} | {cols[2]} | {cols[3]} | "
                f"{cols[4]} | {cols[5]} | {gate_pct} | {med_s} | {p90_s} | {errors} |"
            )
        note = status.get(engine_key)
        if note and not any_rows:
            lines.append(f"| {label} | (skipped) | — | — | — | — | — | — | — | — | — | — | {note} |")
    lines.append("")
    lines.append("## Engine notes / status")
    lines.append("")
    for engine_key in RUN_ORDER:
        note = status.get(engine_key, "not yet run")
        lines.append(f"- **{ENGINES[engine_key]['label']}**: {note}")
    lines.append("")
    lines.append(f"_Generated {time.strftime('%Y-%m-%d %H:%M:%S')}_")
    RESULTS_MD.write_text("\n".join(lines) + "\n")
    print(f"  RESULTS.md updated ({RESULTS_MD})")


# ── main per-engine/set runner ───────────────────────────────────────────────
def run_engine_set(engine_key: str, set_name: str, rows: list[dict]):
    cfg = ENGINES[engine_key]
    path = jsonl_path(engine_key, set_name)
    done_ids = {r["id"] for r in read_jsonl(path)}
    todo = [r for r in rows if r["id"] not in done_ids]
    if cfg["learned"]:
        filtered = []
        for r in todo:
            ex = get_learned_example(r.get("vendor_name", ""), r.get("vendor_domain", ""), r["id"])
            if ex:
                r = dict(r)
                r["_learned_lines"] = ex
                filtered.append(r)
        print(f"  [{engine_key}/{set_name}] {len(filtered)}/{len(todo)} rows have a supplier exemplar")
        todo = filtered
    if not todo:
        print(f"  [{engine_key}/{set_name}] nothing to do ({len(done_ids)} already recorded)")
        return
    print(f"  [{engine_key}/{set_name}] running {len(todo)} docs ...")
    keepalive_ping()
    for i, row in enumerate(todo, 1):
        inv_id, pdf_path = row["id"], row["pdf_local_path"]
        rec = {"id": inv_id, "engine": engine_key, "set": set_name}
        try:
            if cfg["kind"] == "vision":
                prompt = build_learned_prompt(row.get("_learned_lines")) if cfg["learned"] else VISION_PROMPT
                fields, dt, tried = extract_document_vision(pdf_path, cfg["model"], prompt)
                rec.update({"latency_s": dt, "pages_tried": tried, "fields": fields})
            elif cfg["kind"] == "mistral_text":
                fields, mistral_dt, extract_dt, pages = mistral_extract_document(_MISTRAL_ADAPTER, pdf_path)
                rec.update({"latency_s": mistral_dt + extract_dt, "mistral_latency_s": mistral_dt,
                            "extract_latency_s": extract_dt, "pages_tried": pages, "fields": fields})
            else:
                raise RuntimeError(f"unknown engine kind {cfg['kind']}")
            rec["gate_ok"] = gate(rec["fields"]) is not None
            if set_name == "A":
                rec.update(score_against_truth(rec["fields"], row))
        except Exception as e:
            rec["error"] = str(e)[:300]
        append_jsonl(path, rec)
        if i % 10 == 0:
            print(f"    ...{i}/{len(todo)} done ({engine_key}/{set_name})")
            keepalive_ping()
    keepalive_ping()
    render_results_md()


_MISTRAL_ADAPTER = None


def run_engine(engine_key: str, sets: list[str], set_a_rows, set_b_rows):
    global _MISTRAL_ADAPTER
    cfg = ENGINES[engine_key]
    print(f"\n=== engine: {cfg['label']} ({engine_key}) ===")

    if cfg["kind"] == "vision" and cfg["model"] not in ("qwen2.5vl:7b",):
        # non-baseline vision models need availability/capability checks first
        if cfg["model"] == "qwen2.5vl:32b":
            present = ollama_model_names()
            if not any(n == "qwen2.5vl:32b" for n in present):
                print("  waiting for qwen2.5vl:32b pull to finish ...")
                if not poll_for_model("qwen2.5vl:32b"):
                    set_status(engine_key, "SKIPPED — qwen2.5vl:32b never appeared in `ollama list` within max wait")
                    render_results_md()
                    return
        if cfg["model"] == "gemma4-qat31b" and not engine_key.endswith("_learned"):
            sample_pdf = (set_a_rows or set_b_rows)[0]["pdf_local_path"]
            ok, note = smoke_test_vision("gemma4-qat31b", sample_pdf)
            if not ok:
                set_status("gemma31b", f"SKIPPED — not vision-capable: {note}")
                set_status("gemma31b_learned", f"SKIPPED — base engine not vision-capable: {note}")
                render_results_md()
                return
            print(f"  smoke test OK: {note}")

    if engine_key in ("gemma31b_learned",) and load_status().get("gemma31b", "").startswith("SKIPPED"):
        return  # base already failed smoke test
    if engine_key in ("qwen32b_learned",) and load_status().get("qwen32b", "").startswith("SKIPPED"):
        return

    if cfg["kind"] == "mistral_text":
        if _MISTRAL_ADAPTER is None:
            adapter, note = make_mistral_adapter()
            if adapter is None:
                set_status(engine_key, f"SKIPPED — {note}")
                render_results_md()
                return
            _MISTRAL_ADAPTER = adapter
            print(f"  mistral adapter ready ({note})")

    for set_name in sets:
        rows = set_a_rows if set_name == "A" else set_b_rows
        if not rows:
            continue
        run_engine_set(engine_key, set_name, rows)
    set_status(engine_key, "done")
    render_results_md()


def main():
    global N_A, N_B
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="all", choices=list(ENGINES) + ["all"])
    ap.add_argument("--set", default="all", choices=["A", "B", "all"])
    ap.add_argument("--n-a", type=int, default=N_A)
    ap.add_argument("--n-b", type=int, default=N_B)
    args = ap.parse_args()

    N_A, N_B = args.n_a, args.n_b

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"── r2-ocr-bench · engine={args.engine} set={args.set} ──")

    print("loading/sampling SET A ...")
    set_a_rows = get_set_a()
    print(f"  SET A usable rows: {len(set_a_rows)}")
    print("loading/sampling SET B ...")
    set_b_rows = get_set_b()
    print(f"  SET B usable rows: {len(set_b_rows)}")

    sets = ["A", "B"] if args.set == "all" else [args.set]
    engines = RUN_ORDER if args.engine == "all" else [args.engine]

    for engine_key in engines:
        run_engine(engine_key, sets, set_a_rows, set_b_rows)

    render_results_md()
    print("\n── bench complete ──")


if __name__ == "__main__":
    main()
