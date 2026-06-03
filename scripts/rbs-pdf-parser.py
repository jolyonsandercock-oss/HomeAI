#!/usr/bin/env python3
"""Re-parse the 9 failing RBS PDFs with cross-year date detection."""
import subprocess, re, hashlib, glob, os
from datetime import datetime

RBS_CARDS = {"0528": 17, "6874": 18, "0197": 19, "8864": 11, "2621": 12, "3092": 13, "9799": 14}

MONTHS = {"january":1,"february":2,"march":3,"april":4,"may":5,"june":6,
          "july":7,"august":8,"september":9,"october":10,"november":11,"december":12}

def run_sql(batch):
    if not batch: return
    subprocess.run(["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai"],
                   input="\n".join(batch).encode(), capture_output=True)

def parse(filepath):
    text = subprocess.run(["pdftotext", "-layout", filepath, "-"], capture_output=True, text=True).stdout
    
    card_match = re.search(r"5520\s?85\d{2}\s?\d{4}\s?(\d{4})", text)
    if not card_match: return None, 0, 0, []
    acct_id = RBS_CARDS.get(card_match.group(1))
    if not acct_id: return None, 0, 0, []

    # Summary
    prev_bal = None; new_bal = None
    pm = re.search(r"Balance brought forward from.*?\n.*?£?([\d,]+\.\d{2})", text, re.DOTALL)
    nm = re.search(r"New Balance\s*=?\s*£?([\d,]+\.\d{2})", text)
    if pm: prev_bal = float(pm.group(1).replace(",", ""))
    if nm: new_bal = abs(float(nm.group(1).replace(",", "")))  # abs because credit balance has trailing -

    # Statement year and cross-year detection
    dm = re.search(r"Summary\s+(\d{1,2}\s+\w+\s+(\d{4}))", text)
    period_m = re.search(r"(\d{1,2}\s+(\w+))\s+\d{4}\s+-\s+\d{1,2}\s+(\w+)\s+(\d{4})", text)
    
    stmt_year = int(dm.group(2)) if dm else (int(period_m.group(4)) if period_m else 2024)
    cross_year = False
    start_month = 1
    if period_m:
        start_month = MONTHS.get(period_m.group(2).lower(), 1)
        end_month = MONTHS.get(period_m.group(3).lower(), 12)
        cross_year = start_month > end_month
    
    txns = []
    in_section = False
    for line in text.split("\n"):
        line = line.strip()
        if not line: continue
        
        if "BALANCE FROM PREVIOUS STATEMENT" in line.upper():
            in_section = True; continue
        if "NEW BALANCE" in line.upper(): in_section = False; continue
        if "SUB-TOTAL" in line.upper(): continue
        if not in_section: continue

        upper = line.upper()
        if any(s in upper for s in ["CARDHOLDER", "MASTERCARD", "CARD ENDING", "TRANS POST",
                                      "MINIMUM", "INTEREST RATE", "SUMMARY OF", "BANK GIRO", "YOUR NOMINATED"]):
            continue

        m = re.search(r"(\d{1,2}\s+\w{3})(\s+\d{1,2}\s+\w{3})?\s+(?:\d{5,}\s+)?(.+?)\s+([\d,]+\.\d{2})\s*(-)?$", line)
        if not m: continue

        ds = m.group(1); desc = m.group(3).strip()
        amt = float(m.group(4).replace(",", ""))
        if m.group(5): amt = -amt

        if len(desc) < 2: continue
        if desc.upper().startswith(("BALANCE", "SUB-TOTAL", "NEW", "CARDHOLDER", "INTEREST RATE", "TRANS POST", "MINIMUM")): continue

        # Determine year — handle cross-year statements
        trans_month_str = ds.split()[1]
        trans_month = MONTHS.get(trans_month_str.lower(), 1)
        
        if cross_year and trans_month <= 6:
            year = stmt_year
        elif cross_year:
            year = stmt_year - 1
        else:
            year = stmt_year
        
        try: dt = datetime.strptime(ds + " " + str(year), "%d %b %Y").date()
        except: continue

        txns.append((dt, desc[:200], amt))

    return acct_id, prev_bal, new_bal, txns

# Process ALL RBS PDFs with the fixed parser
print("Re-parsing all RBS PDFs with cross-year fix...")
pdfs = sorted(glob.glob("/home_ai/storage/rbs_pdfs/*.pdf"))
ok, fail = 0, 0
total = 0; batch = []

# Delete old PDF rows for a clean re-import
run_sql(["DELETE FROM bank_transactions WHERE source = 'rbs_pdf_final' OR source = 'rbs_pdf_v3';"])

for pdf in pdfs:
    acct_id, prev_bal, new_bal, txns = parse(pdf)
    if not txns: continue
    
    txn_sum = sum(t[2] for t in txns)
    expected = new_bal - prev_bal if prev_bal and new_bal else 0
    diff = abs(txn_sum - expected) if prev_bal and new_bal else 0
    
    if prev_bal and new_bal and diff < 0.10:
        ok += 1; flag = "OK"
    else:
        fail += 1; flag = "FAIL diff=" + str(round(diff, 2))
    
    if diff > 0.10:
        bn = os.path.basename(pdf)[:50]
        print(f"  {flag:25s} {bn:50s} {len(txns):3d} txns  sum={round(txn_sum,2)} expected={round(expected,2)}")
    
    for dt, desc, amt in txns:
        desc = desc.replace("'", "''")
        ikey = hashlib.sha256(("rbs_fix|" + str(dt) + "|" + desc[:30] + "|" + str(round(amt,2)) + "|" + str(acct_id)).encode()).hexdigest()
        batch.append("INSERT INTO bank_transactions (idempotency_key,bank_account_id,transaction_date,description,amount,source,realm) VALUES ('" + ikey + "'," + str(acct_id) + ",'" + str(dt) + "','" + desc + "'," + str(amt) + ",'rbs_pdf_final_v2','personal') ON CONFLICT (idempotency_key) DO NOTHING;")
        total += 1
        if len(batch) >= 3000: run_sql(batch); batch = []

run_sql(batch)
print(f"\n  OK: {ok}/{ok+fail} ({round(100*ok/(ok+fail),1)}%), Total: {total} txns")
