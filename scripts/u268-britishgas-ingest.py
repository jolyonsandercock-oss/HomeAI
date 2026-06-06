import os, re, json, glob, hashlib, asyncio, asyncpg, httpx, claude_call
from datetime import date as _date


def _parsedate(s):
    try:
        return _date.fromisoformat(s) if s else None
    except Exception:
        return None

PDF_DIR = "/tmp/bg_bills"
PDFPLUMBER = "http://homeai-pdfplumber:8003/extract-pdf"
HOST_DIR = "/home_ai/storage/bg_bills"
PROMPT = ("Extract this UK British Gas utility bill as a single JSON object, nothing else: "
          '{"invoice_number": str, "invoice_date": "YYYY-MM-DD", '
          '"gross_amount": number (total incl VAT; NEGATIVE if it is a Credit Note), '
          '"net_amount": number|null, "vat_amount": number|null, '
          '"is_credit_note": bool, "account_number": str}. Bill text:\n\n')


async def main():
    conn = await asyncpg.connect(os.environ["PG_DSN"])
    await conn.execute("SET app.current_entity='1'")
    await conn.execute("SELECT home_ai.set_realm('owner')")
    ok = 0
    async with httpx.AsyncClient(timeout=90) as client:
        for path in sorted(glob.glob(PDF_DIR + "/*.pdf")):
            fn = os.path.basename(path)
            with open(path, "rb") as f:
                r = await client.post(PDFPLUMBER, files={"file": (fn, f, "application/pdf")})
            text = (r.json().get("text") or "") if r.status_code == 200 else ""
            if not text.strip():
                print(f"{fn}: NO TEXT (skip)"); continue
            resp = claude_call.claude_messages({
                "model": "claude-haiku-4-5-20251001", "max_tokens": 400,
                "messages": [{"role": "user", "content": PROMPT + text[:6000]}]})
            raw = resp["content"][0]["text"]
            m = re.search(r"\{[\s\S]*\}", raw)
            d = json.loads(m.group(0)) if m else {}
            inv = str(d.get("invoice_number") or fn)
            gross = d.get("gross_amount")
            idem = "bgportal_" + hashlib.sha256(f"britishgas|{inv}".encode()).hexdigest()
            stored = f"{HOST_DIR}/{fn}"
            try:
                await conn.execute("""
                  INSERT INTO vendor_invoice_inbox
                    (idempotency_key, source_email_id, account, entity_id, vendor_domain, vendor_name,
                     subject, received_at, gross_amount, net_amount, vat_amount, currency, invoice_date,
                     has_pdf, attachment_count, first_attachment_path, status, extraction_method,
                     extraction_confidence, extracted_at, vendor_category, realm, is_statement)
                  VALUES ($1,$2,'admin',1,'britishgas.co.uk','British Gas',$3,now(),$4,$5,$6,'GBP',$7,
                          true,1,$8,'extracted','bg_portal',0.9,now(),'Utilities','work',false)
                  ON CONFLICT (idempotency_key) DO UPDATE
                    SET gross_amount=EXCLUDED.gross_amount, invoice_date=EXCLUDED.invoice_date,
                        net_amount=EXCLUDED.net_amount, vat_amount=EXCLUDED.vat_amount,
                        first_attachment_path=EXCLUDED.first_attachment_path, status='extracted'
                """, idem, f"bgportal:{inv}", f"British Gas {'Credit Note' if d.get('is_credit_note') else 'Invoice'} {inv}",
                    gross, d.get("net_amount"), d.get("vat_amount"), _parsedate(d.get("invoice_date")), stored)
                ok += 1
                print(f"{fn}: {d.get('invoice_date')}  £{gross}")
            except Exception as ex:
                print(f"{fn}: INSERT FAIL {str(ex)[:70]}")
    await conn.close()
    print(f"\nINGESTED: {ok}")


asyncio.run(main())
