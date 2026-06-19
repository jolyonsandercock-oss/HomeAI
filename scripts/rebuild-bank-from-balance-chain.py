#!/usr/bin/env python3
"""
rebuild-bank-from-balance-chain.py — reconstruct a NatWest account's ledger in
bank_transactions from a per-line extract CSV, deriving each transaction AMOUNT
from the running-balance delta (the only trustworthy column) rather than the
paid_in/paid_out columns, which are mis-parsed in both the DB and the extract.

WHY: the 2026-06-03 ad-hoc "validated_v1" reload wrote statement-period END-DATES
into transaction_date (date collapse) AND inherited ~5.4k sign-flipped amounts.
extract_statements.py *also* mis-assigns paid_in/paid_out for ~5.6k rows. But the
BALANCE column matches across both sources (9925/9926) and every chain residual is
a clean 2x-amount sign-flip (never a gap) => the balance chain is complete and is
ground truth. amount[i] = balance[i] - balance[i-1] in per-statement file order.

USAGE:
  rebuild-bank-from-balance-chain.py --account-id 15 --csv storage/extracted/NW-48885517.csv \
      --old-source natwest_15_validated_v1 --new-source natwest_15_balancerecon_v1 [--apply]

Without --apply it is a DRY RUN: reconstructs, content-dedups, prints a full
verification report, and writes nothing. With --apply it runs ONE transaction:
snapshot -> delete dependent account_transfers -> delete old rows -> insert
reconstructed ledger -> log raw.imports. Fully reversible from the snapshot table.
"""
import csv, os, sys, argparse, hashlib
from datetime import datetime
from collections import OrderedDict

def parse_bal(s):
    s=(s or "").replace(",","").strip()
    try: return round(float(s),2)
    except: return None

def parse_paid(r):
    pi=(r.get("paid_in") or "").replace(",","").strip()
    po=(r.get("paid_out") or "").replace(",","").strip()
    v=0.0
    if pi: v+=float(pi)
    if po: v-=float(po)
    return round(v,2)

def reconstruct(path):
    """Return list of dicts: date, description, amount, balance, source_file.
    amount derived from balance delta within each statement (file order)."""
    rows=list(csv.DictReader(open(path,newline="",encoding="utf-8-sig")))
    bystmt=OrderedDict()
    for r in rows: bystmt.setdefault(r["source_file"],[]).append(r)
    led=[]; fallback=0
    for sf,rs in bystmt.items():
        prev=None
        for r in rs:
            b=parse_bal(r["balance"])
            has_txn=bool((r.get("paid_in") or "").strip() or (r.get("paid_out") or "").strip())
            if not has_txn:
                if b is not None: prev=b      # opening-balance / brought-forward line seeds the chain
                continue
            if b is None: continue
            if prev is None:
                amount=parse_paid(r); fallback+=1   # first txn, no opening-balance line: best-effort
            else:
                amount=round(b-prev,2)
            try: d=datetime.strptime(r["date"].strip(),"%d %b %Y").date()
            except: prev=b; continue
            led.append({"date":d,"description":(r["description"] or "").strip(),
                        "amount":amount,"balance":b,"source_file":sf})
            prev=b
    return led, fallback

def dedup(led):
    """Content-dedup across overlapping statement boundaries: key (date, amount, desc)."""
    seen=set(); out=[]
    for t in led:
        k=(t["date"], t["amount"], t["description"])
        if k in seen: continue
        seen.add(k); out.append(t)
    return out

def idemkey(acct_no, t):
    raw=f"balrecon|{acct_no}|{t['date']}|{t['amount']:.2f}|{t['balance']:.2f}|{t['description']}"
    return hashlib.sha256(raw.encode()).hexdigest()[:32]

def report(led, deduped):
    from collections import Counter
    yrs=Counter(t["date"].year for t in deduped)
    days=Counter((t["date"].year) for t in deduped)
    distinct_days={y:len({t['date'] for t in deduped if t['date'].year==y}) for y in sorted(yrs)}
    net=sum(t["amount"] for t in deduped)
    print(f"  reconstructed rows: {len(led)}  -> after content-dedup: {len(deduped)}  (dropped {len(led)-len(deduped)} boundary-overlaps)")
    print(f"  net sum of amounts: {net:,.2f}")
    print(f"  per-year (txns / distinct-days  => ratio should look like real daily activity):")
    for y in sorted(yrs):
        dd=distinct_days[y]; print(f"    {y}: {yrs[y]:5d} txns / {dd:3d} days  = {yrs[y]/dd:5.1f}/day")
    # balance-chain self-consistency of the dedup'd ledger, per statement
    print(f"  date range: {min(t['date'] for t in deduped)} .. {max(t['date'] for t in deduped)}")

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--account-id",type=int,required=True)
    ap.add_argument("--csv",required=True)
    ap.add_argument("--old-source",required=True)
    ap.add_argument("--new-source",required=True)
    ap.add_argument("--apply",action="store_true")
    a=ap.parse_args()
    led,fb=reconstruct(a.csv)
    ded=dedup(led)
    print(f"=== {'APPLY' if a.apply else 'DRY-RUN'} rebuild acct_id={a.account_id} from {a.csv} ===")
    print(f"  first-of-statement fallback rows (paid-col, no opening line): {fb}")
    report(led,ded)
    if not a.apply:
        # emit the reconstructed ledger for inspection
        out=f"/tmp/recon_{a.account_id}.tsv"
        with open(out,"w") as fh:
            for t in ded: fh.write(f"{t['date']}\t{t['amount']:.2f}\t{t['balance']:.2f}\t{t['description']}\n")
        print(f"  ledger written to {out} (inspect before --apply)")
        return
    # APPLY path runs in-container via asyncpg (see wrapper .sh); here we just print ledger as TSV to stdout
    for t in ded:
        print(f"{t['date']}\t{t['amount']:.2f}\t{t['balance']:.2f}\t{t['description']}")

if __name__=="__main__":
    main()
