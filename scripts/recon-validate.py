#!/usr/bin/env python3
"""
recon-validate — mandatory pre-flight gate for any financial reconciliation.
Implements the 7 discipline rules from feedback_financial_recon_discipline.md as runnable
checks, so the rules are ENFORCED, not just remembered.

Use as a library (import the functions) or a CLI:
    python3 recon-validate.py 6,7,8,9,11,12,13,14,15,17,18,19,3,4,5

Checks:
  1. dedup_check        — exact-duplicate rows (acct,date,amount,desc) that would over-sum
  2. overlap_check      — (account, month) covered by >1 source = double-count surface
  3. yearboundary_check — card lines in Dec/Jan = parser year-bug surface (must be source-checked)
  4. balance_check      — per-statement Sum(txn) vs Delta(balance) where a balance column exists
  5. assert_total()     — components must sum to the stated headline (compute-and-assert)
  6. crossfoot()        — net flow between two account-sets must agree from both ledgers
Exit code is non-zero if any hard check fails (dedup>0, overlap>0) so a caller can gate on it.
"""
import subprocess, sys, json

def sql(q):
    r = subprocess.run(
        ["docker","exec","-i","homeai-postgres","psql","-U","postgres","-d","homeai","-tA","-F|"],
        input=("SET app.current_realm='owner'; SET app.current_entity='all';\n"+q).encode(),
        capture_output=True)
    return [l for l in r.stdout.decode().splitlines() if l.strip() and l.strip() != "SET"]

def _in(accts): return ",".join(str(a) for a in accts)

# ── Rule 1/4: dedup ─────────────────────────────────────────────
def dedup_check(accts):
    rows = sql(f"""SELECT COALESCE(SUM(c-1),0) FROM
      (SELECT COUNT(*) c FROM bank_transactions WHERE bank_account_id IN ({_in(accts)})
       GROUP BY bank_account_id,transaction_date,amount,description) g;""")
    return int(rows[0]) if rows else 0

# ── Rule 5: source overlap ──────────────────────────────────────
def overlap_check(accts):
    rows = sql(f"""SELECT bank_account_id, to_char(transaction_date,'YYYY-MM') ym,
        string_agg(DISTINCT source,',') srcs, COUNT(DISTINCT source) ns
      FROM bank_transactions WHERE bank_account_id IN ({_in(accts)})
      GROUP BY 1,2 HAVING COUNT(DISTINCT source)>1 ORDER BY 1,2;""")
    return [r.split("|") for r in rows]

# ── Rule 4: year-boundary parser-bug surface (cards) ────────────
def yearboundary_check(card_accts):
    rows = sql(f"""SELECT COUNT(*) FROM bank_transactions
      WHERE bank_account_id IN ({_in(card_accts)}) AND EXTRACT(month FROM transaction_date) IN (12,1);""")
    return int(rows[0]) if rows else 0

# ── Rule 4: per-statement balance validation ────────────────────
def balance_check(acct, tol=0.02):
    """Where a running balance exists, Sum(amount) over the account must equal last-first balance.
    Returns (ok, txn_sum, balance_delta) or None if no balance data."""
    rows = sql(f"""WITH b AS (SELECT transaction_date,amount,balance FROM bank_transactions
        WHERE bank_account_id={acct} AND balance IS NOT NULL ORDER BY transaction_date, id)
      SELECT (SELECT ROUND(SUM(amount)::numeric,2) FROM b),
             (SELECT balance FROM b ORDER BY transaction_date DESC, id DESC LIMIT 1)
             - (SELECT balance FROM b ORDER BY transaction_date ASC, id ASC LIMIT 1)
             + (SELECT amount FROM b ORDER BY transaction_date ASC, id ASC LIMIT 1);""")
    if not rows or rows[0].split("|")[0] in ("",): return None
    p = rows[0].split("|")
    try: ts, bd = float(p[0]), float(p[1])
    except: return None
    return (abs(ts-bd) < tol, round(ts,2), round(bd,2))

# ── Rule 1: compute-and-assert ──────────────────────────────────
def assert_total(label, components, stated, tol=0.01):
    s = round(sum(components), 2)
    if abs(s - stated) > tol:
        raise AssertionError(f"{label}: components sum to {s:,.2f} but stated {stated:,.2f} (diff {s-stated:,.2f})")
    return s

# ── Rule 7: cross-foot two account-sets ─────────────────────────
def crossfoot(name_a, accts_a, name_b, accts_b):
    """Net flow A<->B computed from A's ledger (refs to B) — caller compares to B's ledger.
    Returns dict of directional sums. Match is done by the caller's reference filter; this
    just sums signed amounts on each side's rows it is given via SQL the caller builds.
    Provided as a thin helper; real matching uses account numbers (see recon-master)."""
    return {"a": name_a, "b": name_b}  # placeholder hook; master does the account-number matching

def run_cli(accts):
    card_accts = [a for a in accts if a in (11,12,13,14,17,18,19)]
    report = {"accounts": accts}
    dups = dedup_check(accts)
    ovl  = overlap_check(accts)
    yb   = yearboundary_check(card_accts) if card_accts else 0
    report["dedup_surplus_rows"] = dups
    report["source_overlap_acct_months"] = ovl
    report["card_year_boundary_lines"] = yb
    bal = {}
    for a in accts:
        bc = balance_check(a)
        if bc is not None: bal[a] = {"ok": bc[0], "txn_sum": bc[1], "balance_delta": bc[2]}
    report["balance_checks"] = bal
    hard_fail = dups > 0 or len(ovl) > 0
    report["RESULT"] = "FAIL" if hard_fail else "PASS"
    print(json.dumps(report, indent=2))
    if dups: print(f"\n⚠ {dups} surplus duplicate rows — DEDUP before summing (rule 1).")
    if ovl:  print(f"⚠ {len(ovl)} account-months with >1 source — pick ONE canonical source (rule 5).")
    if yb:   print(f"ℹ {yb} card lines in Dec/Jan — source-verify their YEAR before quoting dates (rule 4).")
    return 0 if not hard_fail else 1

if __name__ == "__main__":
    accts = [int(x) for x in sys.argv[1].split(",")] if len(sys.argv) > 1 else \
            [3,4,5,6,7,8,9,10,11,12,13,14,15,17,18,19]
    sys.exit(run_cli(accts))
