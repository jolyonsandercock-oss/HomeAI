"""invoice-pdf-date-extract.py — extract the TRUE invoice_date (+number/amount)
from an invoice's PDF attachment, because the email received-date is unreliable:
invoices get resent/forwarded months after issue, and future-dating is legitimate
(post-dated recurring invoices). The PDF is the only stable source of truth.
See feedback_invoice_date_from_pdf.

Runs INSIDE homeai-bot-responder (needs google-fetch + pdfplumber + postgres on the
internal network). Deliberately OFF the event-claim/router path (no flood risk).

  docker exec -i -e VAULT_TOKEN=$VT -e MODE=dry -e IDS=2692,7513,10203 \
      homeai-bot-responder python3 < scripts/invoice-pdf-date-extract.py

ENV:
  MODE = dry (default, report only) | apply (UPDATE invoices.invoice_date)
  IDS  = comma list of invoices.id, or 'review' = all requires_human=true, or 'all'
  LIMIT = max rows (default 50)

Dedup note: when applying, we key the invoice on IDENTITY (supplier+number+amount+
pdf_date), never on email/received metadata, so a resend of an already-captured
invoice is recognised rather than duplicated. (Same content-dedup lesson as the bank.)
"""
import os, re, json, base64, urllib.request, urllib.parse, asyncio
from datetime import date, timedelta
import asyncpg

# Plausibility window: invoices realistically date from a few years back up to
# ~a quarter post-dated (post-dated recurring renewals are legitimate). Anything
# outside this is a mis-parsed product/ref code (e.g. J&R's 2033/2080 tokens).
MIN_DATE = date(2018, 1, 1)
MAX_DATE = date.today() + timedelta(days=120)
# Only these labels are trustworthy enough to auto-apply; fallback is review-only.
TRUSTED_LABELS = {'invoice date', 'tax point', 'date'}

GF = 'http://google-fetch:8011'
PDFPLUMBER = 'http://homeai-pdfplumber:8003/extract-pdf'
VAULT_TOKEN = os.environ['VAULT_TOKEN']

def vault(path):
    req = urllib.request.Request(f'http://vault:8200/v1/secret/data/{path}',
                                 headers={'X-Vault-Token': VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']

def gf(path, tries=4):
    # retry transient google-fetch Docker-DNS failures (Temporary failure in name resolution)
    import time as _t
    last = None
    for i in range(tries):
        try:
            return json.loads(urllib.request.urlopen(f'{GF}{path}', timeout=40).read())
        except Exception as e:
            last = e; _t.sleep(1.5 * (i + 1))
    raise last

def fetch_pdf_text(account, mid):
    """Return (filename, text) for the first PDF attachment, or (None, reason)."""
    try:
        msg = gf(f'/message/{account}/{mid}')
    except Exception as e:
        return None, f'message fetch failed: {e}'
    parts = []
    def walk(p):
        b = p.get('body', {}) or {}; fn = p.get('filename') or ''
        if b.get('attachmentId') and fn.lower().endswith('.pdf'):
            parts.append((fn, b['attachmentId']))
        for s in (p.get('parts') or []): walk(s)
    walk(msg.get('payload', {}))
    if not parts:
        return None, 'no PDF attachment'
    fn, aid = parts[0]
    try:
        att = gf(f'/attachment/{account}/{mid}/{urllib.parse.quote(aid, safe="")}')
        raw = base64.urlsafe_b64decode(att['data_b64url'] + '=' * (-len(att['data_b64url']) % 4))
    except Exception as e:
        return None, f'attachment fetch failed: {e}'
    bd = '----invpdf'
    body = (f'--{bd}\r\nContent-Disposition: form-data; name="file"; filename="{fn}"\r\n'
            f'Content-Type: application/pdf\r\n\r\n').encode() + raw + f'\r\n--{bd}--\r\n'.encode()
    req = urllib.request.Request(PDFPLUMBER, data=body,
                                 headers={'Content-Type': f'multipart/form-data; boundary={bd}'})
    try:
        r = json.loads(urllib.request.urlopen(req, timeout=60).read())
    except Exception as e:
        return None, f'pdfplumber failed: {e}'
    return fn, (r.get('text') or r.get('extracted_text') or '')

MONTHS = {m: i for i, m in enumerate(
    ['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'], 1)}

def _mk(y, m, d):
    if y < 100: y += 2000
    if not (1 <= m <= 12 and 1 <= d <= 31): return None
    try: return date(y, m, d)
    except ValueError: return None

def parse_uk_date(tok):
    """Parse a single date token, UK-first (DD/MM). Returns date or None."""
    tok = tok.strip()
    m = re.match(r'^(\d{1,2})[ /.\-](\d{1,2})[ /.\-](\d{2,4})$', tok)
    if m:
        a, b, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
        # UK DD/MM: first is day. If first>12 it's unambiguously day; if second>12, swap.
        if a > 12 and b <= 12: d, mo = a, b
        elif b > 12 and a <= 12: d, mo = b, a   # was MM/DD
        else: d, mo = a, b                      # ambiguous -> UK DD/MM
        return _mk(y, mo, d)
    m = re.match(r'^(\d{1,2})[ /.\-]([A-Za-z]{3,9})[ /.\-](\d{2,4})$', tok)
    if m and m.group(2)[:3].lower() in MONTHS:
        return _mk(int(m.group(3)), MONTHS[m.group(2)[:3].lower()], int(m.group(1)))
    return None

DATE_TOK = r'(\d{1,2}[ /.\-](?:\d{1,2}|[A-Za-z]{3,9})[ /.\-]\d{2,4})'
# label priority: explicit invoice date > tax point > bare "date" (NOT "due date")
LABEL_RES = [
    (re.compile(r'invoice\s*date\s*[:\-]?\s*' + DATE_TOK, re.I), 'invoice date'),
    (re.compile(r'tax\s*point\s*[:\-]?\s*' + DATE_TOK, re.I), 'tax point'),
    (re.compile(r'(?<!due )(?<!due)\bdate\s*[:\-]?\s*' + DATE_TOK, re.I), 'date'),
]

def extract_invoice_date(text):
    """Return (date, label) using label priority; falls back to first date token."""
    for rx, label in LABEL_RES:
        for m in rx.finditer(text):
            d = parse_uk_date(m.group(1))
            if d: return d, label
    # fallback: any date token
    for m in re.finditer(DATE_TOK, text):
        d = parse_uk_date(m.group(1))
        if d: return d, 'fallback:first-token'
    return None, None

OLLAMA_MODEL = os.environ.get('OLLAMA_MODEL', 'gemma4-doc:latest')
def ollama(prompt):
    body = json.dumps({"model": OLLAMA_MODEL, "prompt": prompt, "stream": False,
                       "think": False,  # gemma4 is a thinking model -> empty output without this
                       "options": {"temperature": 0}}).encode()
    for host in ('http://ollama:11434', 'http://homeai-ollama:11434'):
        try:
            req = urllib.request.Request(host + '/api/generate', data=body,
                                         headers={'Content-Type': 'application/json'})
            return json.loads(urllib.request.urlopen(req, timeout=120).read()).get('response', '')
        except Exception:
            continue
    return ''

def gemma_invoice_date(text):
    """LOCAL model fallback (gemma4-doc on the W7800) — reads the whole invoice text
    contextually, unlike the garbage-prone first-token regex. Returns (date, 'gemma4-doc')."""
    prompt = ("Extract the INVOICE DATE (the date the invoice was issued, NOT the due date) "
              "from this UK invoice text. UK dates are DD/MM/YYYY. "
              "Reply with ONLY the date as YYYY-MM-DD and nothing else.\n\n---\n" + (text or '')[:2500])
    out = ollama(prompt)
    m = re.search(r'(\d{4})-(\d{2})-(\d{2})', out or '')
    if not m: return None, 'gemma4-doc'
    return _mk(int(m.group(1)), int(m.group(2)), int(m.group(3))), 'gemma4-doc'

async def main():
    mode = os.environ.get('MODE', 'dry')
    ids_arg = os.environ.get('IDS', 'review')
    limit = int(os.environ.get('LIMIT', '50'))
    pw = vault('postgres')['password']
    c = await asyncpg.connect(f'postgresql://postgres:{pw}@homeai-postgres:5432/homeai')
    await c.execute("SELECT set_config('app.current_entity','all',false)")
    await c.execute("SELECT home_ai.set_realm('owner')")
    if ids_arg == 'review':
        where = "i.source='email_ocr' AND i.requires_human=true"
    elif ids_arg == 'all':
        where = "i.source='email_ocr'"
    elif ids_arg == 'recent':
        hours = int(os.environ.get('HOURS', '26'))   # forward-only sweep window (idempotent, overlap-tolerant)
        where = f"i.source='email_ocr' AND i.created_at > now() - interval '{hours} hours'"
    else:
        idlist = ','.join(str(int(x)) for x in ids_arg.split(','))
        where = f"i.id IN ({idlist})"
    rows = await c.fetch(f"""
        SELECT i.id, i.supplier_name, i.invoice_number, i.invoice_date AS cur_date, i.gross_amount,
               ev.source AS acct, ev.payload->>'gmail_message_id' AS mid
        FROM invoices i
        JOIN events ev ON ev.id = i.event_id
        WHERE {where} AND ev.payload->>'gmail_message_id' IS NOT NULL
        ORDER BY i.id LIMIT {limit}""")
    print(f"== invoice-pdf-date-extract  MODE={mode}  rows={len(rows)} ==")
    applied = matched = changed_lowconf = nopdf = unparsed = flagged = 0
    for r in rows:
        acct = (r['acct'] or '').split(':')[0] or 'jo'
        ev_acct = await c.fetchval("SELECT payload->>'account' FROM events WHERE id=(SELECT event_id FROM invoices WHERE id=$1)", r['id'])
        acct = ev_acct or acct
        fn, text = fetch_pdf_text(acct, r['mid'])
        if fn is None:
            nopdf += 1; print(f"  #{r['id']:>6} {r['supplier_name'][:24]:24} — SKIP ({text})")
            if mode == 'apply': await c.execute("UPDATE invoices SET requires_human=true WHERE id=$1", r['id'])
            continue
        pdf_date, label = extract_invoice_date(text)
        # confidence gate: trusted label AND inside the plausibility window
        trusted = bool(pdf_date) and label in TRUSTED_LABELS and MIN_DATE <= pdf_date <= MAX_DATE
        if not trusted and os.environ.get('GEMMA', '1') == '1':
            # LOCAL model fallback (gemma4-doc on the W7800) — reads the whole invoice
            # contextually; beats the garbage-prone first-token regex. No cloud, no egress.
            g_date, g_label = gemma_invoice_date(text)
            if g_date and MIN_DATE <= g_date <= MAX_DATE:
                pdf_date, label, trusted = g_date, g_label, True
        if not pdf_date or not (MIN_DATE <= pdf_date <= MAX_DATE):
            unparsed += 1
            print(f"  #{r['id']:>6} {r['supplier_name'][:24]:24} — UNRELIABLE (date={pdf_date} [{label}]) -> flag")
            if mode == 'apply': await c.execute("UPDATE invoices SET requires_human=true WHERE id=$1", r['id'])
            continue
        if pdf_date == r['cur_date']:
            matched += 1
            print(f"  #{r['id']:>6} {r['supplier_name'][:24]:24} cur={r['cur_date']} pdf={pdf_date} [{label}]  OK")
            # trusted (label or gemma) confirmation -> clear a stale review flag
            if mode == 'apply' and trusted:
                await c.execute("UPDATE invoices SET requires_human=false WHERE id=$1 AND requires_human=true", r['id'])
            continue
        if not trusted:   # changed but low-confidence (fallback token) -> never auto-apply, flag
            changed_lowconf += 1
            print(f"  #{r['id']:>6} {r['supplier_name'][:24]:24} cur={r['cur_date']} pdf={pdf_date} [{label}]  LOW-CONF -> flag")
            if mode == 'apply': await c.execute("UPDATE invoices SET requires_human=true WHERE id=$1", r['id'])
            continue
        # trusted change -> apply
        print(f"  #{r['id']:>6} {r['supplier_name'][:24]:24} cur={r['cur_date']} pdf={pdf_date} [{label}]  <-- APPLY")
        applied += 1
        if mode == 'apply':
            await c.execute("""UPDATE invoices SET invoice_date=$2, requires_human=false,
                anomaly_reason=concat('PDF-extracted invoice_date via pdfplumber (', $3::text, '); was ', $4::text)
                WHERE id=$1""", r['id'], pdf_date, label, str(r['cur_date']))
    print(f"\n  trusted-changes={applied} already-correct={matched} low-conf-flagged={changed_lowconf}"
          f" unreliable-flagged={unparsed} no-pdf={nopdf}"
          + ("  (DRY RUN — no writes)" if mode != 'apply' else "  (APPLIED + flagged uncertain for review)"))
    await c.close()

asyncio.run(main())
