#!/usr/bin/env python3
"""u296-statement-recon.py — supplier statement reconciliation engine.

NOTE ON NUMBERING: the originating brief asked for "u295-statement-recon.py",
but u295 was already taken by a8578c2 (dynamic denylist, committed same day).
Bumped to u296 per feedback_check_sprint_number_first (git log is the source
of truth, not a brief written before that commit landed).

Supplier STATEMENTS (vendor_invoice_inbox.is_statement=true) list every
invoice the supplier issued for a period. This parses each statement's
invoice lines (ref/date/amount) and matches them against the real invoice
rows already ingested (is_statement=false) to produce a TRUE per-supplier
capture rate + a concrete missing-invoice list — not a proxy count.

Extraction ladder (cheapest first):
  1. pdf_text_extracted already on the row (no fetch at all).
  2. pdf_local_path -> pdfplumber :8003/extract-pdf (host-reachable).
  3. no local PDF -> Gmail attachment fetch INSIDE homeai-bot-responder
     (google-fetch is ai-internal, host can't reach it directly) — same
     idiom as u284-pdf-fetch-backfill.sh — then pdfplumber as above.
  4. Regex ladder for the big three known formats (St Austell Brewery,
     J&R Foodservice, Tintagel Brewing Company — patterns written from
     real PDFs, see evidence in the V300 migration header / this file's
     git history). Any other vendor, or a big-three regex that yields
     ZERO invoice lines (format drift), falls back to gemma4-doc via
     ollama with a strict JSON-lines schema. think:false is REQUIRED
     (gemma4 is a thinking model; omitting it returns empty responses).

Matching: same-vendor candidate pool from vendor_invoice_inbox
(is_statement=false, status NOT IN ignored/duplicate). Two methods:
  'invoice_number' — statement ref normalised (case/space/leading-zero
                      stripped) equals the candidate's own ref, extracted
                      from the candidate's EMAIL SUBJECT via a per-vendor
                      pattern (there is no structured invoice_number column
                      on vendor_invoice_inbox).
  'date_amount'    — invoice_date +/-3 days AND |gross_amount-line_amount|
                      <= 0.02, used when no ref match (or vendor has no
                      known ref pattern).
Unmatched lines are the missing-invoice list; each is left as
match_method='unmatched', matched_invoice_id NULL.

Idempotent: a statement_id is only ever picked up ONCE by the default
population query (WHERE id NOT IN (SELECT DISTINCT statement_id FROM
statement_recon_lines)) — so the DAILY cron only parses NEW statements.
Re-running on an already-processed id (FORCE=1 IDS=<id>) DELETEs that
id's existing rows first, so re-parses are a clean replace, never a dupe.

Duplicate-statement guard: the sweep found the SAME statement forwarded
under multiple inbox ids repeatedly. Before inserting real lines for a
newly-processed statement, its (vendor_key, sorted line-set) fingerprint is
compared against every already-processed statement's fingerprint (recomputed
from statement_recon_lines, cheap). A match against a DIFFERENT id gets a
single match_method='duplicate' marker row instead of a full re-insert (so
capture-rate math is never double-counted, and the id still counts as
"processed" for the idempotency gate above).

Usage:
  python3 scripts/u296-statement-recon.py                # MODE=dry, LIMIT=150
  MODE=apply python3 scripts/u296-statement-recon.py
  MODE=apply IDS=5226,5290,5301,5285,5338,1150,1600,1706 \\
      FORCE=1 python3 scripts/u296-statement-recon.py     # hand-verification set

ENV: MODE=dry|apply (default dry)  LIMIT=<n> (default 150)
     IDS=<csv of vendor_invoice_inbox.id>  (default: live query, is_statement=true)
     FORCE=1  bypass the "not yet processed" filter (re-parse named IDS)
     SKIP_AUTOFLAG=1  skip the is_statement cheap-sweep pre-step
     SKIP_FETCH=1  never attempt a Gmail fetch (regex/gemma4 only run on
                   whatever text is already available — used for fast dry runs)

Prints a per-vendor capture table + OPS_ROWS=<statements processed
(parsed+recon'd) + statements autoflagged>, matching the house convention
(see scripts/u-deadletter-hygiene.sh).
"""
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta

PDFPLUMBER = "http://localhost:8003/extract-pdf"
OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "gemma4-doc:latest")
FETCH_DIR = "/home_ai/storage/invoices/fetched"
HTTP_TIMEOUT = 60
OLLAMA_TIMEOUT = int(os.environ.get("OLLAMA_TIMEOUT", "180"))  # cold model load can exceed 90s

MODE = os.environ.get("MODE", "dry")
LIMIT = int(os.environ.get("LIMIT", "150"))
FORCE = os.environ.get("FORCE", "0") == "1"
IDS_ENV = os.environ.get("IDS", "").strip()
SKIP_AUTOFLAG = os.environ.get("SKIP_AUTOFLAG", "0") == "1"
SKIP_FETCH = os.environ.get("SKIP_FETCH", "0") == "1"


# ─────────────────────────── psql helpers ───────────────────────────
def esc(s) -> str:
    return str(s if s is not None else "").replace("'", "''")


def psql(sql: str, timeout=60):
    """Run a query, return list of rows (list of str), tab-separated."""
    full = "SET app.current_entity='all'; SET app.current_realm='owner'; " + sql
    r = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai",
         "-tA", "-F", "\t", "-c", full],
        capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(f"  [psql ERROR] {r.stderr.strip()[:300]}", flush=True)
        return []
    return [ln.split("\t") for ln in r.stdout.splitlines() if ln.strip() and ln != "SET"]


def psql_exec(sql: str, timeout=60) -> bool:
    """Run a mutating statement under ON_ERROR_STOP. Returns success bool."""
    full = "SET app.current_entity='all'; SET app.current_realm='owner'; " + sql
    r = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai",
         "-v", "ON_ERROR_STOP=1", "-tA", "-c", full],
        capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(f"  [psql_exec ERROR] {r.stderr.strip()[:300]}", flush=True)
    return r.returncode == 0


# ─────────────────────────── PDF text acquisition ───────────────────────────
def pdfplumber_extract(pdf_bytes: bytes, filename: str = "doc.pdf"):
    bd = "----u296stmt"
    body = (f'--{bd}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            f'Content-Type: application/pdf\r\n\r\n').encode() + pdf_bytes + f"\r\n--{bd}--\r\n".encode()
    req = urllib.request.Request(PDFPLUMBER, data=body,
                                  headers={"Content-Type": f"multipart/form-data; boundary={bd}"})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=HTTP_TIMEOUT).read()).get("text", "") or None
    except Exception as e:
        print(f"    pdfplumber error: {e}", flush=True)
        return None


def fetch_pdf_via_gmail(account: str, msgid: str, row_id: int):
    """Same idiom as u284-pdf-fetch-backfill.sh: hop into homeai-bot-responder
    (only container with google-fetch DNS reachability), pull the first PDF
    attachment, return raw bytes. Timeout-bounded, returns None on any error."""
    py = (
        "import os, json, urllib.request, sys\n"
        "a, m = os.environ['ACCT'], os.environ['MSGID']\n"
        "try:\n"
        "    msg = json.loads(urllib.request.urlopen(f'http://google-fetch:8011/message/{a}/{m}', timeout=20).read())\n"
        "    def walk(p):\n"
        "        is_pdf = (p.get('mimeType') == 'application/pdf' or (p.get('filename') or '').lower().endswith('.pdf'))\n"
        "        if is_pdf and p.get('body', {}).get('attachmentId'):\n"
        "            return p['body']['attachmentId']\n"
        "        for c in p.get('parts', []) or []:\n"
        "            r = walk(c)\n"
        "            if r: return r\n"
        "    att = walk(msg.get('payload', msg))\n"
        "    if not att:\n"
        "        print('NOPDF'); sys.exit(0)\n"
        "    data = json.loads(urllib.request.urlopen(f'http://google-fetch:8011/attachment/{a}/{m}/{att}', timeout=60).read())\n"
        "    print(data.get('data_b64url') or 'NODATA')\n"
        "except Exception as e:\n"
        "    print('ERR:' + str(e)[:80])\n"
    )
    try:
        r = subprocess.run(
            ["docker", "exec", "-i", "-e", f"ACCT={account}", "-e", f"MSGID={msgid}",
             "homeai-bot-responder", "python3", "-"],
            input=py, capture_output=True, text=True, timeout=90)
    except Exception:
        return None
    out = (r.stdout or "").strip()
    if not out or out in ("NOPDF", "NODATA") or out.startswith("ERR:"):
        return None
    try:
        raw = base64.urlsafe_b64decode(out + "=" * (-len(out) % 4))
    except Exception:
        return None
    os.makedirs(FETCH_DIR, exist_ok=True)
    path = f"{FETCH_DIR}/{row_id}.pdf"
    try:
        with open(path, "wb") as f:
            f.write(raw)
    except Exception:
        return raw  # still usable even if we couldn't persist it
    if MODE == "apply":
        psql_exec(f"UPDATE vendor_invoice_inbox SET pdf_local_path='{esc(path)}', "
                  f"pdf_fetched_at=now() WHERE id={int(row_id)} AND pdf_local_path IS NULL;")
    return raw


def get_statement_text(row: dict):
    """row: id, pdf_text_extracted, pdf_local_path, account, source_email_id.
    Returns (text, source_tag) or (None, error_reason)."""
    if row.get("pdf_text_extracted"):
        return row["pdf_text_extracted"], "db_text"
    if row.get("pdf_local_path"):
        try:
            with open(row["pdf_local_path"], "rb") as f:
                data = f.read()
            text = pdfplumber_extract(data, os.path.basename(row["pdf_local_path"]))
            if text:
                return text, "local_pdf"
        except Exception as e:
            print(f"    local-pdf read failed for #{row['id']}: {e}", flush=True)
    if SKIP_FETCH:
        return None, "no-text-skip-fetch"
    if row.get("source_email_id"):
        raw = fetch_pdf_via_gmail(row.get("account") or "admin", row["source_email_id"], row["id"])
        if raw:
            try:
                text = pdfplumber_extract(raw, f"{row['id']}.pdf")
                if text:
                    return text, "gmail_fetch"
            except Exception as e:
                return None, f"pdfplumber-after-fetch:{e}"
        return None, "gmail-fetch-failed"
    return None, "no-source"


# ─────────────────────────── vendor line parsers (regex ladder) ───────────────────────────
def _num(s):
    try:
        return abs(round(float(str(s).replace(",", "").replace("£", "").strip()), 2))
    except Exception:
        return None


def parse_staustell(text):
    out = []
    pat = re.compile(
        r"^(\d{2}/\d{2}/\d{4})\s+(Invoice|Credit Memo|Payment)\s+(Trade|Other)\s+(\S+)\s+"
        r"(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s+(\S+)", re.M)
    for date_s, doctype, _tt, ref, amt1, _amt2, _due in pat.findall(text):
        if doctype != "Invoice":
            continue
        try:
            d = datetime.strptime(date_s, "%d/%m/%Y").date()
        except Exception:
            continue
        amt = _num(amt1)
        if amt is None:
            continue
        out.append({"ref": ref, "date": d, "amount": amt})
    return out


def parse_jr(text):
    out = []
    pat = re.compile(
        r"^(\d{1,2}/\d{1,2}/\d{2})\s+(Invoice|Credit Note)\s+(\d+)(?:\s+\S+)?\s+"
        r"([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s*$", re.M)
    for date_s, doctype, ref, amt1, _bal in pat.findall(text):
        if doctype != "Invoice":
            continue
        try:
            d = datetime.strptime(date_s, "%d/%m/%y").date()
        except Exception:
            continue
        amt = _num(amt1)
        if amt is None:
            continue
        out.append({"ref": ref, "date": d, "amount": amt})
    return out


def parse_tintagel(text):
    out = []
    pat = re.compile(
        r"^(\d{2}/\d{2}/\d{4})\s+Invoice No\.(\d+):\s+Due\s+\d{2}/\d{2}/\d{4}\.\s+"
        r"([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s*$", re.M)
    for date_s, ref, amt1, _open in pat.findall(text):
        try:
            d = datetime.strptime(date_s, "%d/%m/%Y").date()
        except Exception:
            continue
        amt = _num(amt1)
        if amt is None:
            continue
        out.append({"ref": ref, "date": d, "amount": amt})
    return out


# vendor_domain -> (line-parser, inbox-subject-ref-pattern, display key)
VENDOR_PROFILES = {
    "staustellbrewery.co.uk": (parse_staustell, re.compile(r"Customer Invoice\s+(SI\d{2}-\d+)", re.I), "staustell"),
    "jrf.lls.com":            (parse_jr,        re.compile(r"\bINV\s+(\d+)", re.I),                    "jr_foodservice"),
    "tintagelbrewery.co.uk":  (parse_tintagel,  re.compile(r"\bInvoice\s+(\d+)\b", re.I),               "tintagel_brewery"),
}

FALLBACK_PROMPT = (
    "This is a UK supplier ACCOUNT STATEMENT (a list of invoices/credits/payments for a "
    "trading account over a period, NOT a single invoice). Extract ONLY the INVOICE lines "
    "(skip Payments, Credit Notes/Memos, brought-forward balances, and aged-debt summary "
    "rows). Return ONLY a JSON object, no other text:\n"
    '{"lines":[{"ref":"<invoice number/reference exactly as printed>", '
    '"date":"<YYYY-MM-DD, the invoice/document date not the due date>", '
    '"amount":<original invoice value as a number, not a running balance>}]}\n'
    "Numbers plain (no currency symbols, no thousands commas)."
)


def ollama_fallback(text):
    """Returns a list of lines, or None on a MODEL-CALL failure (timeout/conn).
    None is NOT the same as a genuine empty statement: callers treat None as a
    transient error, so the statement stays UNPROCESSED and is retried on the
    next daily run instead of being permanently marked done with 0 lines."""
    prompt = FALLBACK_PROMPT + "\n\n---\n" + text[:6000]
    body = json.dumps({"model": OLLAMA_MODEL, "prompt": prompt, "stream": False,
                        "think": False,  # gemma4 is a thinking model -> empty output without this
                        "format": "json", "options": {"temperature": 0}}).encode()
    resp = None
    for attempt in (1, 2):
        req = urllib.request.Request(OLLAMA_URL, data=body, headers={"Content-Type": "application/json"})
        try:
            resp = json.loads(urllib.request.urlopen(req, timeout=OLLAMA_TIMEOUT).read()).get("response", "")
            break
        except Exception as e:
            print(f"    ollama fallback attempt {attempt} failed: {e}", flush=True)
            time.sleep(2)
    if resp is None:
        return None
    try:
        j = json.loads(resp)
    except Exception:
        m = re.search(r"\{.*\}", resp, re.S)
        if not m:
            return []
        try:
            j = json.loads(m.group(0))
        except Exception:
            return []
    lines = j.get("lines") if isinstance(j, dict) else (j if isinstance(j, list) else [])
    out = []
    for it in lines or []:
        if not isinstance(it, dict):
            continue
        ref = str(it.get("ref") or "").strip()
        try:
            d = datetime.strptime(str(it.get("date"))[:10], "%Y-%m-%d").date()
        except Exception:
            d = None
        amt = _num(it.get("amount"))
        if ref and d and amt is not None:
            out.append({"ref": ref, "date": d, "amount": amt})
    return out


def parse_statement_lines(vendor_domain, text):
    """Returns (lines, extraction_method)."""
    prof = VENDOR_PROFILES.get(vendor_domain)
    if prof:
        lines = prof[0](text)
        if lines:
            return lines, "regex:" + prof[2]
        # known vendor but 0 lines = format drift; fall through to gemma4
    return ollama_fallback(text), "gemma4-doc"


# ─────────────────────────── matching ───────────────────────────
def norm_ref(s):
    if not s:
        return ""
    s = re.sub(r"\s+", "", str(s).strip().upper())
    s = re.sub(r"(?<![0-9])0+(?=[0-9])", "", s)
    return s


def vendor_key(vendor_domain, vendor_name):
    prof = VENDOR_PROFILES.get(vendor_domain)
    if prof:
        return prof[2]
    if vendor_domain and len(vendor_domain) >= 4 and not re.search(r"intuit|xero|sage|quickbooks|sidetrade", vendor_domain, re.I):
        return vendor_domain
    key = re.sub(r"[^a-z0-9]", "", (vendor_name or "").split("<")[0].lower())[:16]
    return key or (vendor_domain or "unknown")


def extract_inbox_ref(vendor_domain, subject):
    prof = VENDOR_PROFILES.get(vendor_domain)
    if not prof:
        return None
    m = prof[1].search(subject or "")
    return m.group(1) if m else None


def get_candidates(vendor_domain):
    rows = psql(f"""SELECT id, subject, invoice_date, gross_amount FROM vendor_invoice_inbox
        WHERE vendor_domain = '{esc(vendor_domain)}' AND is_statement = false
          AND status NOT IN ('ignored','duplicate')""")
    out = []
    for r in rows:
        if len(r) < 4:
            continue
        cid, subj, invdate, gross = r
        try:
            d = datetime.strptime(invdate, "%Y-%m-%d").date() if invdate else None
        except Exception:
            d = None
        try:
            g = float(gross) if gross else None
        except Exception:
            g = None
        out.append({"id": int(cid), "subject": subj, "date": d, "gross": g})
    return out


def match_line(line, candidates, vendor_domain):
    ref_n = norm_ref(line["ref"])
    if ref_n:
        for c in candidates:
            if norm_ref(extract_inbox_ref(vendor_domain, c["subject"])) == ref_n:
                return c["id"], "invoice_number"
    best = None
    for c in candidates:
        if c["date"] is None or c["gross"] is None:
            continue
        if abs((c["date"] - line["date"]).days) <= 3 and abs(c["gross"] - line["amount"]) <= 0.02:
            best = c["id"]
            break
    if best is not None:
        return best, "date_amount"
    return None, "unmatched"


# ─────────────────────────── dedup fingerprinting ───────────────────────────
def fingerprint(vkey, lines):
    key = sorted(f"{norm_ref(l['ref'])}|{l['date']}|{l['amount']:.2f}" for l in lines)
    return vkey + "::" + hashlib.md5("|".join(key).encode()).hexdigest()


def load_known_fingerprints():
    """Rebuild fingerprint -> canonical statement_id from what's already in
    statement_recon_lines (excluding duplicate markers)."""
    rows = psql("""SELECT statement_id, vendor_key, invoice_ref, line_date, line_amount
        FROM statement_recon_lines WHERE match_method <> 'duplicate'
        ORDER BY statement_id""")
    by_stmt = {}
    for r in rows:
        if len(r) < 5:
            continue
        sid, vkey, ref, ld, amt = r
        by_stmt.setdefault((int(sid), vkey), []).append(
            {"ref": ref, "date": ld, "amount": float(amt) if amt else 0.0})
    fps = {}
    for (sid, vkey), lines in by_stmt.items():
        key = sorted(f"{norm_ref(l['ref'])}|{l['date']}|{l['amount']:.2f}" for l in lines)
        fp = vkey + "::" + hashlib.md5("|".join(key).encode()).hexdigest()
        fps.setdefault(fp, sid)  # first (lowest id, since ORDER BY statement_id) wins as canonical
    return fps


# ─────────────────────────── autoflag assist ───────────────────────────
def run_autoflag():
    rows = psql(r"""SELECT id, subject,
          CASE
            WHEN pdf_text_extracted ~* 'statement\s*(of\s*account|summary)' THEN 'statement-of-account/summary marker'
            WHEN pdf_text_extracted ~* 'balance brought forward' THEN 'balance brought forward marker'
            WHEN pdf_text_extracted ~* 'previous balance' THEN 'previous balance marker'
            ELSE 'text marker'
          END
        FROM vendor_invoice_inbox
        WHERE is_statement = false
          AND subject ~* '\mstatement\M'
          AND pdf_text_extracted ~* '(statement\s*(of\s*account|summary))|balance brought forward|previous balance'""")
    n = 0
    for r in rows:
        if len(r) < 3:
            continue
        rid, subj, evidence = r
        note = f"u296 autoflag: subject={subj!r} evidence={evidence}"
        if MODE == "apply":
            ok = psql_exec(
                f"UPDATE vendor_invoice_inbox SET is_statement = true WHERE id = {int(rid)} AND is_statement = false;"
            )
            if ok:
                psql_exec(
                    f"INSERT INTO _stmt_autoflag_log (invoice_id, evidence) VALUES ({int(rid)}, '{esc(note)}');"
                )
        print(f"  autoflag #{rid}: {subj[:60] if subj else ''}  ({evidence})", flush=True)
        n += 1
    return n


# ─────────────────────────── main ───────────────────────────
def main():
    print(f"== u296-statement-recon MODE={MODE} LIMIT={LIMIT} FORCE={FORCE} ==", flush=True)

    autoflagged = 0
    if not SKIP_AUTOFLAG:
        print("-- autoflag assist (is_statement=false rows with statement evidence) --", flush=True)
        autoflagged = run_autoflag()
        print(f"  autoflagged={autoflagged}\n", flush=True)

    # pdf_text_extracted contains REAL embedded newlines — psql's -tA row output
    # is newline-delimited, so selecting it raw corrupts row-splitting (each
    # embedded newline becomes a bogus extra "row"). Encode to a control-char
    # marker in SQL and decode back to '\n' in Python (see _undash below).
    PTEXT = r"replace(pdf_text_extracted, chr(10), chr(1))"
    if IDS_ENV:
        ids = [int(x) for x in re.findall(r"\d+", IDS_ENV)]
        where_extra = f"id IN ({','.join(str(i) for i in ids)})"
        not_done = "" if FORCE else " AND id NOT IN (SELECT DISTINCT statement_id FROM statement_recon_lines)"
        rows = psql(f"""SELECT id, vendor_domain, vendor_name, account, source_email_id,
              pdf_local_path, {PTEXT}
            FROM vendor_invoice_inbox WHERE {where_extra}{not_done} ORDER BY id""")
    else:
        rows = psql(f"""SELECT id, vendor_domain, vendor_name, account, source_email_id,
              pdf_local_path, {PTEXT}
            FROM vendor_invoice_inbox
            WHERE is_statement = true
              AND id NOT IN (SELECT DISTINCT statement_id FROM statement_recon_lines)
            ORDER BY (pdf_text_extracted IS NOT NULL) DESC,
                     (pdf_local_path IS NOT NULL) DESC,
                     received_at DESC
            LIMIT {LIMIT}""")

    print(f"-- population: {len(rows)} statement(s) to process --", flush=True)

    known_fps = load_known_fingerprints()
    stats = {}  # vendor_key -> dict(statements, lines, matched, missing, missing_value)
    parse_ok = {}  # extraction_method -> count
    processed = 0
    errors = 0

    for r in rows:
        if len(r) < 7:
            errors += 1
            continue
        rid_s, vdom, vname, acct, semail, plocal, ptext = r[:7]
        rid = int(rid_s)
        ptext = ptext.replace("\x01", "\n") if ptext else None
        try:
            row = {"id": rid, "pdf_text_extracted": ptext or None, "pdf_local_path": plocal or None,
                   "account": acct or "admin", "source_email_id": semail or None}
            text, src = get_statement_text(row)
            if not text:
                print(f"  #{rid} {vdom or vname or '?':30} — NO TEXT ({src})", flush=True)
                errors += 1
                continue

            lines, method = parse_statement_lines(vdom, text)
            vkey = vendor_key(vdom, vname)

            if lines is None:
                # MODEL-CALL failure (ollama timeout/unreachable), not a real
                # empty statement — leave UNPROCESSED so the next run retries.
                print(f"  #{rid} {vkey:20} src={src:12} — model-call failed, will retry next run", flush=True)
                errors += 1
                continue
            parse_ok[method] = parse_ok.get(method, 0) + 1

            if not lines:
                print(f"  #{rid} {vkey:20} src={src:12} method={method:18} — 0 invoice lines found", flush=True)
                # still counts as processed (idempotency gate needs a row) — record a
                # zero-line marker so it isn't re-picked forever.
                if MODE == "apply":
                    psql_exec(f"DELETE FROM statement_recon_lines WHERE statement_id={rid};")
                    psql_exec(f"""INSERT INTO statement_recon_lines
                        (statement_id, vendor_key, invoice_ref, match_method)
                        VALUES ({rid}, '{esc(vkey)}', NULL, 'unmatched');""")
                processed += 1
                continue

            fp = fingerprint(vkey, lines)
            dup_of = known_fps.get(fp)
            if dup_of is not None and dup_of != rid:
                print(f"  #{rid} {vkey:20} src={src:12} method={method:18} — DUPLICATE of statement #{dup_of} "
                      f"({len(lines)} lines, skipped)", flush=True)
                if MODE == "apply":
                    psql_exec(f"DELETE FROM statement_recon_lines WHERE statement_id={rid};")
                    psql_exec(f"""INSERT INTO statement_recon_lines
                        (statement_id, vendor_key, invoice_ref, match_method)
                        VALUES ({rid}, '{esc(vkey)}', 'DUP-OF-{dup_of}', 'duplicate');""")
                processed += 1
                continue
            known_fps[fp] = rid

            candidates = get_candidates(vdom) if vdom else []
            v = stats.setdefault(vkey, {"statements": 0, "lines": 0, "matched": 0, "missing": 0, "missing_value": 0.0})
            v["statements"] += 1

            to_insert = []
            n_matched = 0
            for ln in lines:
                mid, mmethod = match_line(ln, candidates, vdom) if vdom else (None, "unmatched")
                v["lines"] += 1
                if mid is not None:
                    v["matched"] += 1
                    n_matched += 1
                else:
                    v["missing"] += 1
                    v["missing_value"] += ln["amount"]
                to_insert.append((ln, mid, mmethod))

            print(f"  #{rid} {vkey:20} src={src:12} method={method:18} lines={len(lines):3} "
                  f"matched={n_matched}/{len(lines)}", flush=True)

            if MODE == "apply":
                psql_exec(f"DELETE FROM statement_recon_lines WHERE statement_id={rid};")
                for ln, mid, mmethod in to_insert:
                    match_col = str(mid) if mid is not None else "NULL"
                    psql_exec(f"""INSERT INTO statement_recon_lines
                        (statement_id, vendor_key, invoice_ref, line_date, line_amount,
                         matched_invoice_id, match_method)
                        VALUES ({rid}, '{esc(vkey)}', '{esc(ln['ref'])}', '{ln['date'].isoformat()}',
                                {ln['amount']}, {match_col}, '{mmethod}');""")
            processed += 1
        except Exception as e:
            errors += 1
            print(f"  #{rid} ERROR: {e}", flush=True)
            continue

    print(f"\n-- parse coverage: {parse_ok} --", flush=True)
    print(f"-- processed={processed} errors={errors} autoflagged={autoflagged} --\n", flush=True)

    print("-- per-vendor capture (this run's contribution) --", flush=True)
    hdr = f"{'vendor':22} {'stmts':>6} {'lines':>6} {'matched':>8} {'missing':>8} {'capture%':>9} {'missing_val':>13}"
    print(hdr, flush=True)
    for vkey, v in sorted(stats.items(), key=lambda kv: -kv[1]["missing_value"]):
        pct = round(100.0 * v["matched"] / v["lines"], 1) if v["lines"] else 0.0
        print(f"{vkey:22} {v['statements']:6} {v['lines']:6} {v['matched']:8} {v['missing']:8} "
              f"{pct:8.1f}% {v['missing_value']:13.2f}", flush=True)

    ops_rows = processed + autoflagged
    print(f"\nOPS_ROWS={ops_rows}", flush=True)

    if MODE == "apply":
        psql_exec(f"""
          INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,target_rel,
              freshness_sql,freshness_sla_hours,notes)
          VALUES ('statement_recon','recon','scripts/u296-statement-recon.py','10 6 * * *',
              'statement_recon_lines',
              'SELECT max(finished_at) FROM ops.pipeline_runs WHERE name=''statement_recon'' AND status=''ok''',
              26, 'U296: supplier-statement line recon vs vendor_invoice_inbox')
          ON CONFLICT (name) DO NOTHING;
          SELECT ops.record_pipeline_run('statement_recon','ok', now(), {ops_rows},
              'processed={processed} autoflagged={autoflagged} errors={errors}');
        """)


if __name__ == "__main__":
    main()
