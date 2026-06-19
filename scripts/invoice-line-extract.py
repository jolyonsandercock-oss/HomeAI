"""invoice-line-extract.py — extract invoice LINE ITEMS into vendor_invoice_lines
from the PDF, via pdfplumber text -> local gemma4-doc (JSON). Targets
vendor_invoice_inbox rows (the FK target). Off the n8n event path.

Per-supplier formats differ wildly (St Austell kegs/wine vs J&R coded grocery
lines), so we let gemma4-doc read the whole invoice and emit structured JSON
rather than per-supplier regex. Cross-foots sum(line_net) against the invoice net
to set extraction_confidence; mismatches are kept but flagged low-confidence.

J&R pub/cafe split: the delivery code in the PDF — TOM106 = pub (Old Malt House),
MAL125 = cafe (Swirl) — is parsed directly and written to lines.department
(authoritative, not the guessed inbox.site). See feedback_cafe_vendor_truth.

  docker exec -i -e VAULT_TOKEN=$VT -e MODE=dry -e IDS=<targets|ids|supplier> \
      -e YEAR=2026 -e LIMIT=400 homeai-bot-responder python3 < scripts/invoice-line-extract.py

ENV: MODE=dry|apply  IDS=targets(6 suppliers)|<inbox ids csv>|<name>  YEAR=2026
     LIMIT=400  FORCE=0 (skip invoices that already have lines)  OLLAMA_MODEL=gemma4-doc:latest
"""
import os, re, json, base64, urllib.request, urllib.parse, asyncio
import asyncpg

GF = 'http://google-fetch:8011'
PDFPLUMBER = 'http://homeai-pdfplumber:8003/extract-pdf'
OLLAMA_MODEL = os.environ.get('OLLAMA_MODEL', 'gemma4-doc:latest')
VT = os.environ['VAULT_TOKEN']
SUPPLIER_RE = r'austell|j ?& ?r|jr food|forest|dole|kingfisher|bidfresh|bidfood'

def vault(p):
    r = urllib.request.Request(f'http://vault:8200/v1/secret/data/{p}', headers={'X-Vault-Token': VT})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())['data']['data']

def gf(p):
    return json.loads(urllib.request.urlopen(f'{GF}{p}', timeout=30).read())

def pdf_text(acct, mid):
    try:
        msg = gf(f'/message/{acct}/{mid}')
    except Exception as e:
        return None, f'msg:{e}'
    parts = []
    def w(p):
        b = p.get('body', {}) or {}; fn = p.get('filename') or ''
        if b.get('attachmentId') and fn.lower().endswith('.pdf'): parts.append((fn, b['attachmentId']))
        for s in (p.get('parts') or []): w(s)
    w(msg.get('payload', {}))
    if not parts: return None, 'no-pdf'
    fn, aid = parts[0]
    try:
        att = gf(f'/attachment/{acct}/{mid}/{urllib.parse.quote(aid, safe="")}')
        raw = base64.urlsafe_b64decode(att['data_b64url'] + '=' * (-len(att['data_b64url']) % 4))
    except Exception as e:
        return None, f'att:{e}'
    bd = '----L'
    body = (f'--{bd}\r\nContent-Disposition: form-data; name="file"; filename="{fn}"\r\n'
            f'Content-Type: application/pdf\r\n\r\n').encode() + raw + f'\r\n--{bd}--\r\n'.encode()
    req = urllib.request.Request(PDFPLUMBER, data=body, headers={'Content-Type': f'multipart/form-data; boundary={bd}'})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=60).read()).get('text', ''), None
    except Exception as e:
        return None, f'pdfplumber:{e}'

LINE_PROMPT = (
    "You are extracting LINE ITEMS from a UK supplier invoice. Return ONLY a JSON array, "
    "no prose. Each element: {\"code\":string, \"description\":string, \"qty\":number, "
    "\"unit\":string, \"unit_price\":number, \"line_net\":number, \"category\":string}. "
    "'unit' is the pack size (e.g. '1x900g','50LTR','') and 'category' is the section header "
    "(e.g. FROZEN, CHILLED, AMBIENT, NON FOOD) or ''. Include ONLY product line items — "
    "EXCLUDE VAT analysis, subtotals, totals, delivery lines, addresses. Numbers plain (no symbols).\n\n---\n")

def ollama(prompt):
    body = json.dumps({"model": OLLAMA_MODEL, "prompt": prompt, "stream": False,
                       "format": "json", "options": {"temperature": 0}}).encode()
    for host in ('http://ollama:11434', 'http://homeai-ollama:11434'):
        try:
            req = urllib.request.Request(host + '/api/generate', data=body, headers={'Content-Type': 'application/json'})
            return json.loads(urllib.request.urlopen(req, timeout=180).read()).get('response', '')
        except Exception:
            continue
    return ''

def parse_lines(resp):
    if not resp: return []
    # ollama format=json may return an object wrapping the array, or the array directly
    try:
        j = json.loads(resp)
    except Exception:
        m = re.search(r'\[.*\]', resp, re.S)
        if not m: return []
        try: j = json.loads(m.group(0))
        except Exception: return []
    if isinstance(j, dict):
        for v in j.values():
            if isinstance(v, list): j = v; break
        else: j = []
    out = []
    for it in (j if isinstance(j, list) else []):
        if not isinstance(it, dict): continue
        def num(x):
            try: return float(str(x).replace(',', '').replace('£', '').strip())
            except Exception: return None
        out.append({'code': str(it.get('code', '') or '')[:40], 'description': str(it.get('description', '') or '')[:300],
                    'qty': num(it.get('qty')), 'unit': str(it.get('unit', '') or '')[:30],
                    'unit_price': num(it.get('unit_price')), 'line_net': num(it.get('line_net')),
                    'category': str(it.get('category', '') or '')[:40]})
    return out

def jr_department(text):
    if re.search(r'\bTOM106\b', text): return 'pub'
    if re.search(r'\bMAL125\b', text): return 'cafe'
    return None

def parse_net_total(text):
    """The invoice's own stated Ex-VAT/net total — authoritative cross-foot target.
    Layouts vary: 'Total Exc. VAT 668.73' (St Austell), '133.68 Ex VAT' (J&R),
    'Goods Total ...', 'Net Total ...'."""
    pats = [r'Total\s+Exc\.?\s*VAT[^\d]{0,6}([\d,]+\.\d{2})',
            r'([\d,]+\.\d{2})\s*Ex(?:c)?\.?\s*VAT\b',
            r'(?:Goods|Net|Sub)[\s-]*Total[^\d]{0,6}([\d,]+\.\d{2})',
            r'Total\s+Net[^\d]{0,6}([\d,]+\.\d{2})']
    for p in pats:
        m = re.search(p, text, re.I)
        if m:
            try: return round(float(m.group(1).replace(',', '')), 2)
            except Exception: pass
    return None

async def main():
    mode = os.environ.get('MODE', 'dry')
    ids = os.environ.get('IDS', 'targets')
    year = os.environ.get('YEAR', '2026')
    limit = int(os.environ.get('LIMIT', '400'))
    force = os.environ.get('FORCE', '0') == '1'
    pw = vault('postgres')['password']
    c = await asyncpg.connect(f'postgresql://postgres:{pw}@homeai-postgres:5432/homeai')
    await c.execute("SELECT set_config('app.current_entity','all',false)")
    await c.execute("SELECT home_ai.set_realm('owner')")
    if ids == 'targets':
        where = f"vendor_name ~* '{SUPPLIER_RE}' AND (invoice_date >= '{year}-01-01' OR received_at >= '{year}-01-01')"
    elif re.fullmatch(r'[\d,]+', ids):
        where = f"id IN ({','.join(str(int(x)) for x in ids.split(','))})"
    else:
        where = f"vendor_name ~* '{ids}' AND (invoice_date >= '{year}-01-01' OR received_at >= '{year}-01-01')"
    rows = await c.fetch(f"""SELECT id, vendor_name, account, site, realm, source_email_id, invoice_date,
        net_amount, gross_amount FROM vendor_invoice_inbox WHERE {where} AND source_email_id IS NOT NULL
        ORDER BY invoice_date DESC NULLS LAST LIMIT {limit}""")
    print(f"== invoice-line-extract MODE={mode} candidates={len(rows)} ==", flush=True)
    done = skipped = noped = nolines = badfoot = 0
    for r in rows:
        if not force and await c.fetchval("SELECT 1 FROM vendor_invoice_lines WHERE invoice_id=$1 LIMIT 1", r['id']):
            skipped += 1; continue
        acct = r['account'] or 'admin'
        text, err = pdf_text(acct, r['source_email_id'])
        if not text:
            noped += 1; print(f"  inbox#{r['id']} {r['vendor_name'][:22]:22} — no PDF ({err})", flush=True); continue
        lines = parse_lines(ollama(LINE_PROMPT + text[:6000]))
        if not lines:
            nolines += 1; print(f"  inbox#{r['id']} {r['vendor_name'][:22]:22} — gemma returned 0 lines", flush=True); continue
        dept = jr_department(text) if re.search(r'j ?& ?r|jr food', r['vendor_name'], re.I) else (r['site'] if r['site'] in ('pub', 'cafe') else None)
        foot = sum(l['line_net'] for l in lines if l['line_net'] is not None)
        net = parse_net_total(text) or (float(r['net_amount']) if r['net_amount'] is not None else (float(r['gross_amount']) if r['gross_amount'] else None))
        conf = 0.95 if (net and abs(foot - net) <= max(0.05, net * 0.02)) else (0.6 if net else 0.5)
        if net and abs(foot - net) > max(0.05, net * 0.02): badfoot += 1
        tag = '' if conf >= 0.95 else f'  CROSS-FOOT {foot:.2f} vs net {net}'
        print(f"  inbox#{r['id']} {r['vendor_name'][:22]:22} dept={dept or '-':4} lines={len(lines)} foot={foot:.2f}{tag}", flush=True)
        if mode == 'apply':
            async with c.transaction():
                await c.execute("DELETE FROM vendor_invoice_lines WHERE invoice_id=$1", r['id'])
                for i, l in enumerate(lines, 1):
                    await c.execute("""INSERT INTO vendor_invoice_lines
                        (invoice_id,line_no,description,qty,unit,unit_price,line_net,category_hint,
                         department,extracted_by,extraction_confidence,raw_payload,realm)
                        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'gemma4-doc',$10,$11::jsonb,$12)""",
                        r['id'], i, l['description'], l['qty'], l['unit'], l['unit_price'], l['line_net'],
                        l['category'] or None, dept, conf, json.dumps(l), r['realm'] or 'work')
        done += 1
    print(f"\n  extracted={done} skipped(have lines)={skipped} no-pdf={noped} no-lines={nolines} cross-foot-off={badfoot}"
          + ("  (DRY)" if mode != 'apply' else "  (APPLIED)"), flush=True)
    await c.close()

asyncio.run(main())
