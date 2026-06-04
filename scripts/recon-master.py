#!/usr/bin/env python3
"""
recon-master — long-term reconciliation of all transfers between Jo's accounts and the
companies. "Me as an individual" = personal accounts + RBS cards (consolidated); ATR and
Estates are separate counterparties. Salary & rent are EXCLUDED from the loan, shown as memo.

Honours feedback_financial_recon_discipline.md:
  rule1 compute-and-assert · rule2 DB-derive · rule3 unique/symmetric keys (account numbers)
  rule4 source-verified card dates · rule5 dedup · rule6 enumerate all accounts · rule7 cross-foot
Gated by recon-validate.py.
"""
import subprocess, sys, json, html, csv
sys.path.insert(0, "/home_ai/scripts")
import importlib.util
spec = importlib.util.spec_from_file_location("rv", "/home_ai/scripts/recon-validate.py")
rv = importlib.util.module_from_spec(spec); spec.loader.exec_module(rv)

def sql(q): return rv.sql(q)
def gbp(x): return f"£{x:,.2f}"

# ── NODES (rule 6: enumerate all accounts) ──────────────────────
ME_PERSONAL = [6,7,8,9]          # personal current/savings (10=Joint handled separately)
ME_CARDS    = [11,12,13,14,17,18,19]
ME          = ME_PERSONAL + ME_CARDS
ATR         = [3,4,15]            # 48885525 not loaded
EST         = [5]
ALL         = ME + ATR + EST + [10]

# ── ME <-> ATR : bank side, deduped, ATLANTIC refs, salary/rent EXCLUDED ─────
def sum_dir(acct_in, refs, exclude=("SALARY","RENT"), sign_pos_label="in"):
    refclause = " OR ".join(f"description ILIKE '%{r}%'" for r in refs)
    exclause  = "".join(f" AND description NOT ILIKE '%{e}%'" for e in exclude)
    rows = sql(f"""WITH d AS (SELECT DISTINCT ON (bank_account_id,transaction_date,amount,LEFT(description,40))
        amount FROM bank_transactions WHERE bank_account_id IN ({','.join(map(str,acct_in))})
        AND ({refclause}){exclause}
        ORDER BY bank_account_id,transaction_date,amount,LEFT(description,40))
      SELECT COALESCE(ROUND(SUM(CASE WHEN amount>0 THEN amount END)::numeric,2),0),
             COALESCE(ROUND(SUM(CASE WHEN amount<0 THEN -amount END)::numeric,2),0) FROM d;""")
    p = rows[0].split("|"); return float(p[0]), float(p[1])

# acct 6 etc. referencing ATR: +ve = ATR->Jo, -ve = Jo->ATR
atr_to_jo_bank, jo_to_atr_bank = sum_dir(ME_PERSONAL, ["ATLANTIC ROAD TRAD","ATLANTIC TRADING"])
# savings drawdowns (FROM A/C 48747300) into acct 6 — ATR->Jo
rows = sql("""WITH d AS (SELECT DISTINCT ON (transaction_date,amount) amount FROM bank_transactions
   WHERE bank_account_id IN (6,7,8,9) AND description ILIKE '%48747300%' ORDER BY transaction_date,amount)
   SELECT COALESCE(ROUND(SUM(amount)::numeric,2),0) FROM d WHERE amount>0;""")
atr_to_jo_savings = float(rows[0])
# ATR clearing Jo's cards (Faster Payment into cards from ATR) — verified £6k, ATR->Jo
atr_to_jo_cards = 6000.00   # 2026-04-20 £1k ->****3092, 2026-04-21 £5k ->****2621 (source-verified)

atr_to_jo = rv.assert_total("ATR->Jo", [atr_to_jo_bank, atr_to_jo_savings, atr_to_jo_cards], 263132.50)
jo_to_atr = rv.assert_total("Jo->ATR", [jo_to_atr_bank], 193980.00)
bank_net_atr = round(jo_to_atr - atr_to_jo, 2)   # -ve => Jo owes ATR

# ── Card injections (Dojo/iZettle) — SOURCE-VERIFIED dates (rule 4) ──────────
# Each row source-verified against the original RBS PDF this session; DB year-stamps were
# wrong on the *2019-12-23 and 2024-12-20 pair (corrected here). Total is asserted.
CARD_INJ = [  # date, card, amount, target, source_doc
 ("2019-12-02","****6874",  5000.00,"ATR","StatementArchive_22 Dec 2019.pdf"),
 ("2019-12-23","****0197",  5000.00,"ATR","StatementArchive_4 Jan 2020.pdf"),       # *DB had 2020-12-23
 ("2019-12-03","****0528",  5000.00,"EST","StatementArchive_27 Dec 2019.pdf"),
 ("2022-01-17","****3092",  -633.28,"ATR","StatementArchive_22 Jan 2022.pdf"),      # refund
 ("2023-12-13","****9799", 10000.00,"ATR","StatementArchive_27 Dec 2023.pdf"),
 ("2024-02-12","****3092",  2000.00,"ATR","StatementArchive_22 Feb 2024.pdf"),
 ("2024-12-20","****3092",  1000.00,"ATR","StatementArchive_22 Jan 2025.pdf"),      # *DB had 2025-12-20
 ("2024-12-20","****8864",  1000.00,"ATR","StatementArchive_4 Jan 2025.pdf"),       # *DB had 2025-12-20
 ("2025-01-15","****3092",  5000.00,"ATR","StatementArchive_22 Jan 2025.pdf"),
 ("2025-01-16","****3092",  5000.00,"ATR","StatementArchive_22 Jan 2025.pdf"),
 ("2025-01-28","****2621",  5000.00,"ATR","StatementArchive_27 Feb 2025.pdf"),
 ("2025-12-29","****2621",  5000.00,"ATR","RBS CSV export 2026-06-01"),
 ("2026-01-23","****3092",  1000.00,"ATR","RBS CSV export 2026-06-01"),
 ("2026-01-29","****2621",  5000.00,"ATR","RBS CSV export 2026-06-01"),
 ("2026-01-29","****2621", -5000.00,"ATR","RBS CSV export 2026-06-01"),             # reversal, net 0
]
card_atr = rv.assert_total("card->ATR", [a for _,_,a,t,_ in CARD_INJ if t=="ATR"], 44366.72)
card_est = rv.assert_total("card->EST", [a for _,_,a,t,_ in CARD_INJ if t=="EST"], 5000.00)

# Final Me<->ATR loan
me_owes_atr = rv.assert_total("Me owes ATR", [-bank_net_atr, -card_atr], 24785.78)

# ── ME <-> ESTATES : deduped, account-number + name refs (rule 3) ────────────
est_to_jo, jo_to_est = sum_dir(ME_PERSONAL, ["17046041","ATLANTIC ROAD ESTA","ATLANTIC ESTATES"], exclude=())
est_to_jo = rv.assert_total("EST->Jo", [est_to_jo], 337948.46)
jo_to_est = rv.assert_total("Jo->EST", [jo_to_est], 59353.00)
net_est = round(est_to_jo - jo_to_est, 2)                 # +ve => Estates paid Jo more
me_owes_est = rv.assert_total("Me owes EST", [net_est, -card_est], 273595.46)

# ── Salary & rent MEMO (excluded from loan) ─────────────────────
rows = sql("""WITH d AS (SELECT DISTINCT ON (transaction_date,amount,LEFT(description,40)) amount,description
   FROM bank_transactions WHERE bank_account_id IN (6,7,8,9)
   AND (description ILIKE '%ATLANTIC ROAD TRAD%' OR description ILIKE '%ATLANTIC TRADING%')
   ORDER BY transaction_date,amount,LEFT(description,40))
   SELECT COALESCE(ROUND(SUM(amount) FILTER (WHERE description ILIKE '%SALARY%')::numeric,2),0),
          COALESCE(ROUND(SUM(amount) FILTER (WHERE description ILIKE '%RENT%')::numeric,2),0) FROM d;""")
p = rows[0].split("|"); salary_memo, rent_memo = float(p[0]), float(p[1])

# ── ATR <-> ESTATES (context, one-sided due to ATR feed gaps) ───
atr_to_est = 143244.37   # captured on Estates receiving side (acct 5)
est_to_atr = 22185.57    # captured on ATR receiving side (acct 15, the standing order)

print("=== GATE ===")
gate = rv.run_cli(ALL)
print("\n=== ASSERTIONS ALL PASSED ===")
print(f"Me<->ATR  loan: Jo owes ATR {gbp(me_owes_atr)}  (bank net {gbp(-bank_net_atr)} - card {gbp(card_atr)})")
print(f"Me<->EST  loan: Jo owes EST {gbp(me_owes_est)}  (net {gbp(net_est)} - card {gbp(card_est)})")
print(f"memo: salary {gbp(salary_memo)}  rent {gbp(rent_memo)}")
print(f"ATR<->EST: ATR->EST {gbp(atr_to_est)} (mostly rent), EST->ATR {gbp(est_to_atr)} (standing order)")

# ── master CSV ──────────────────────────────────────────────────
csv_path = "/home_ai/storage/master-reconciliation-2026-06-03.csv"
def fetch_lines(acct_in, refs, label, exclude=()):
    refclause = " OR ".join(f"description ILIKE '%{r}%'" for r in refs)
    exclause  = "".join(f" AND description NOT ILIKE '%{e}%'" for e in exclude)
    out=[]
    rows = sql(f"""SELECT string_agg(x,E'\n') FROM (SELECT DISTINCT ON (bank_account_id,transaction_date,amount,LEFT(description,40))
        transaction_date||'|'||amount||'|'||regexp_replace(LEFT(description,55),'\\s+',' ','g') x,
        bank_account_id,transaction_date,amount,LEFT(description,40)
      FROM bank_transactions WHERE bank_account_id IN ({','.join(map(str,acct_in))}) AND ({refclause}){exclause}
      ORDER BY bank_account_id,transaction_date,amount,LEFT(description,40)) s;""")
    for blob in rows:
        for l in blob.split("\n"):
            q=l.split("|")
            if len(q)>=3:
                try: out.append((label,q[0],round(float(q[1]),2),q[2].strip()))
                except: pass
    return out

with open(csv_path,"w",newline="") as f:
    w=csv.writer(f); w.writerow(["relationship","date","amount_gbp","direction","narrative","source"])
    for lab,d,a,narr in sorted(fetch_lines(ME_PERSONAL,["ATLANTIC ROAD TRAD","ATLANTIC TRADING"],"Me<->ATR",exclude=("SALARY","RENT"))):
        w.writerow(["Me<->ATR",d,f"{abs(a):.2f}","ATR->Me" if a>0 else "Me->ATR",narr,"Personal 36345245 / ATLANTIC TRADING"])
    for d,card,a,t,doc in CARD_INJ:
        w.writerow([f"Me<->{t} (card)",d,f"{a:.2f}",f"Me->{t} (Dojo/iZettle)",card,doc])
    for lab,d,a,narr in sorted(fetch_lines(ME_PERSONAL,["17046041","ATLANTIC ROAD ESTA","ATLANTIC ESTATES"],"Me<->EST")):
        w.writerow(["Me<->EST",d,f"{abs(a):.2f}","EST->Me" if a>0 else "Me->EST",narr,"Personal 36345245 <-> AREL 17046041"])
    w.writerow([])
    w.writerow(["SUMMARY","",f"Jo owes ATR {gbp(me_owes_atr)}; Jo owes Estates {gbp(me_owes_est)}; memo salary {gbp(salary_memo)}, rent {gbp(rent_memo)}","","",""])
print("CSV:", csv_path)

# stash computed values for the emailer
json.dump(dict(jo_to_atr=jo_to_atr,atr_to_jo=atr_to_jo,atr_to_jo_bank=atr_to_jo_bank,
  atr_to_jo_savings=atr_to_jo_savings,atr_to_jo_cards=atr_to_jo_cards,bank_net_atr=bank_net_atr,
  card_atr=card_atr,card_est=card_est,me_owes_atr=me_owes_atr,est_to_jo=est_to_jo,jo_to_est=jo_to_est,
  net_est=net_est,me_owes_est=me_owes_est,salary_memo=salary_memo,rent_memo=rent_memo,
  atr_to_est=atr_to_est,est_to_atr=est_to_atr,gate=gate,csv_path=csv_path),
  open("/tmp/recon_master_vals.json","w"))
print("VALUES -> /tmp/recon_master_vals.json")
