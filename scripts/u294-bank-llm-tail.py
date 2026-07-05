#!/usr/bin/env python3
"""u294-bank-llm-tail.py — classify residual uncategorised bank clusters.

Reads the registry categories live (minus 'transfer' kind, which Tasks 2/3
own deterministically) and asks qwen2.5:7b to pick ONE for each cluster of
same-shaped, same-sign, same-entity description lines. Idempotent: only
ever touches rows still at category IS NULL, gated per-cluster by the same
cluster-key expression used to build the cluster.

Cluster key: upper(regexp_replace(substring(description for 24),'[0-9]','','g'))
             || ':' || sign(amount) || ':' || entity_id
Only clusters with sum(abs(amount)) >= 250 OR count(*) >= 10 go to the model;
smaller ones go straight to needs_review (not worth the tokens).

Run on host (needs localhost:11434 ollama):
  python3 scripts/u294-bank-llm-tail.py --limit 5      # dry-run, 5 clusters
  python3 scripts/u294-bank-llm-tail.py                # full run
"""
import json
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime

# psql -tA still emits command-completion tags (SET, CREATE TABLE, INSERT 0 n,
# UPDATE n, DELETE n) inline with the tuple output when a -c string chains
# several statements with ';'. Data rows never match this shape, so filter
# them out rather than only excluding the literal 'SET' (bit us once already:
# UPDATE ... RETURNING id came back with an extra phantom row from the
# trailing 'UPDATE n' tag).
_CMD_TAG_RE = re.compile(
    r"^(SET|BEGIN|COMMIT|ROLLBACK|CREATE [A-Z ]+|DROP [A-Z ]+|ALTER [A-Z ]+|"
    r"TRUNCATE( TABLE)?|INSERT \d+ \d+|UPDATE \d+|DELETE \d+|SELECT \d+)$")

MODEL = "qwen2.5:7b"
OLLAMA_URL = "http://127.0.0.1:11434/api/generate"
CATEGORY_SOURCE = "llm:qwen7b:u294v1"

LIMIT = None
if "--limit" in sys.argv:
    LIMIT = int(sys.argv[sys.argv.index("--limit") + 1])

ALLOWED_SQL = """SELECT category, kind FROM bank_category_registry
                 WHERE kind <> 'transfer'"""

CLUSTER_SQL = """
  SELECT upper(regexp_replace(substring(description for 24),'[0-9]','','g'))
         ||':'||sign(amount)::int||':'||entity_id AS ckey,
         count(*) n, sum(abs(amount))::numeric(14,2) vol,
         (array_agg(description ORDER BY abs(amount) DESC))[1:5] samples,
         min(amount) min_amt, max(amount) max_amt, entity_id
    FROM bank_transactions
   WHERE category IS NULL
   GROUP BY 1, entity_id
  HAVING sum(abs(amount)) >= 250 OR count(*) >= 10
   ORDER BY vol DESC"""


def psql(sql: str) -> list[list[str]]:
    out = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres",
         "-d", "homeai", "-tA", "-F", "\t", "-c",
         f"SET app.current_entity='all'; SET app.current_realm='owner'; {sql}"],
        capture_output=True, text=True, timeout=60).stdout
    return [l.split("\t") for l in out.splitlines()
            if l.strip() and not _CMD_TAG_RE.match(l.strip())]


def psql_exec(sql: str, ok_tag: str) -> bool:
    r = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres",
         "-d", "homeai", "-v", "ON_ERROR_STOP=1", "-tA", "-c",
         f"SET app.current_entity='all'; SET app.current_realm='owner'; {sql}"],
        capture_output=True, text=True, timeout=60)
    return r.returncode == 0 and ok_tag in r.stdout


def esc(s: str) -> str:
    return (s or "").replace("'", "''")


def parse_pg_array(raw: str) -> list[str]:
    """Parse a Postgres text-array literal like {"a","b"} from -tA output."""
    if not raw or raw in ("{}", ""):
        return []
    body = raw.strip()
    if body.startswith("{") and body.endswith("}"):
        body = body[1:-1]
    items = []
    cur = ""
    in_quotes = False
    i = 0
    while i < len(body):
        ch = body[i]
        if ch == '"' and (i == 0 or body[i - 1] != "\\"):
            in_quotes = not in_quotes
            i += 1
            continue
        if ch == "," and not in_quotes:
            items.append(cur)
            cur = ""
            i += 1
            continue
        cur += ch
        i += 1
    if cur:
        items.append(cur)
    return [it.replace('\\"', '"') for it in items]


def build_prompt(cats: list[str], n: int, vol: str, samples: list[str],
                  min_amt: str, max_amt: str, entity_id: str, sign: int) -> str:
    cats_line = ", ".join(cats)
    samples_block = "\n".join(f"- {s}" for s in samples)
    direction = "CREDITS (money coming IN)" if sign > 0 else "DEBITS (money going OUT)"
    personal_note = ""
    if entity_id in ("3", "4") and sign < 0:
        personal_note = (
            "\nNote: this is a PERSONAL account (entity 3/4). Unspecific outflows "
            "that don't fit a specific category should be 'personal_spend', NOT "
            "'needs_review'.\n"
        )
    parts = [
        "You are categorising UK bank-statement lines for a pub/property owner.\n",
        "Allowed categories (answer with EXACTLY one of these, verbatim): ",
        cats_line,
        "\nIf genuinely unsure answer needs_review. NEVER guess a transfer category ",
        "— those are handled elsewhere and are not in your allowed list.",
        "\nIf the sample text does not clearly identify the counterparty or purpose, ",
        "answer needs_review — do not guess.",
        personal_note,
        f"\nAll {n} lines below are {direction}, totalling GBP {vol}, "
        f"amount range {min_amt} to {max_amt}:\n",
        samples_block,
        '\nReturn ONLY JSON on one line, no other text: {"category": "...", "reason": "..."}',
    ]
    return "".join(parts)


def validate(cand: str, kinds: dict, sign: int, max_abs: float):
    """Hard validators (code, not prompt hopes). Returns (category, violation|None).

    a. Direction: cost/tax kinds require negative clusters; income requires
       positive. financing can go either way, EXCEPT financing_advance must be
       positive and financing_repayment must be negative (enforced by name).
    b. bank_fee magnitude cap: genuine bank fees are small; a cluster whose
       largest |amount| exceeds £500 cannot be bank_fee (the -£195k CHAPS case).
    """
    kind = kinds.get(cand)
    if kind in ("cost", "tax") and sign > 0:
        return "needs_review", f"direction:{cand}({kind})-on-credit"
    if kind == "income" and sign < 0:
        return "needs_review", f"direction:{cand}(income)-on-debit"
    if cand == "financing_advance" and sign < 0:
        return "needs_review", "direction:financing_advance-on-debit"
    if cand == "financing_repayment" and sign > 0:
        return "needs_review", "direction:financing_repayment-on-credit"
    if cand == "bank_fee" and max_abs > 500:
        return "needs_review", f"magnitude:bank_fee-max-abs-{max_abs:.2f}>500"
    return cand, None


def classify(prompt: str) -> dict:
    req = urllib.request.Request(
        OLLAMA_URL, method="POST",
        data=json.dumps({
            "model": MODEL, "prompt": prompt, "stream": False,
            "options": {"temperature": 0, "num_predict": 120},
        }).encode(),
        headers={"Content-Type": "application/json"})
    raw = json.loads(urllib.request.urlopen(req, timeout=120).read()).get("response", "").strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        raw = raw[4:] if raw.lower().startswith("json") else raw
    try:
        return json.loads(raw[raw.index("{"):raw.rindex("}") + 1])
    except Exception:
        return {}


def main():
    allowed_rows = psql(ALLOWED_SQL)
    kinds = {r[0]: r[1] for r in allowed_rows if len(r) >= 2 and r[0]}
    allowed = set(kinds)
    if not allowed:
        print("ERROR: empty allowed-category set from registry, aborting")
        sys.exit(1)
    cats_list = sorted(allowed)
    print(f"{datetime.now().isoformat()} u294 T5 start: {len(allowed)} allowed categories "
          f"(transfers excluded): {cats_list}")

    psql_exec("""CREATE TABLE IF NOT EXISTS _backup_u294_task5 AS
                 SELECT id, category, category_source FROM bank_transactions WHERE false;
                 SELECT 'OK';""", "OK")

    clusters = psql(CLUSTER_SQL)
    if LIMIT is not None:
        clusters = clusters[:LIMIT]
    print(f"{datetime.now().isoformat()} {len(clusters)} clusters gated to the model "
          f"(vol>=250 or n>=10)")

    totals: dict[str, int] = {}
    total_updated = 0
    errors = 0

    for row in clusters:
        if len(row) < 7:
            continue
        ckey, n_s, vol_s, samples_raw, min_amt, max_amt, entity_id = row[:7]
        samples = parse_pg_array(samples_raw)
        try:
            n = int(n_s)
        except ValueError:
            n = 0

        # cluster sign is encoded in the key (…:<sign>:<entity>)
        try:
            sign = int(ckey.rsplit(":", 2)[1])
        except (IndexError, ValueError):
            sign = 1 if float(max_amt) > 0 else -1
        max_abs = max(abs(float(min_amt)), abs(float(max_amt)))

        category = "needs_review"
        violation = None
        try:
            prompt = build_prompt(cats_list, n, vol_s, samples, min_amt, max_amt,
                                  entity_id, sign)
            res = classify(prompt)
            cand = (res.get("category") or "").strip()
            if cand in allowed:
                category, violation = validate(cand, kinds, sign, max_abs)
            else:
                category = "needs_review"
                if cand:
                    violation = f"non-registry:{cand[:40]}"
        except Exception as e:
            errors += 1
            print(f"CLUSTER {ckey} n={n} vol={vol_s} ERROR {str(e)[:120]} -> needs_review")
            category = "needs_review"

        confidence = 0.70 if category != "needs_review" else 0

        # backup members of this cluster before touching them
        ckey_expr = ("upper(regexp_replace(substring(description for 24),'[0-9]','','g'))"
                     "||':'||sign(amount)::int||':'||entity_id")
        psql_exec(f"""
            INSERT INTO _backup_u294_task5
            SELECT id, category, category_source FROM bank_transactions
             WHERE category IS NULL AND {ckey_expr} = '{esc(ckey)}';
            SELECT 'OK';""", "OK")

        updated = psql(f"""
            UPDATE bank_transactions
               SET category = '{esc(category)}',
                   category_confidence = {confidence},
                   category_source = '{esc(CATEGORY_SOURCE)}'
             WHERE category IS NULL AND {ckey_expr} = '{esc(ckey)}'
             RETURNING id;""")
        rows_touched = len(updated)
        total_updated += rows_touched
        totals[category] = totals.get(category, 0) + rows_touched

        viol = f" VIOLATION={violation}" if violation else ""
        print(f"CLUSTER {ckey} n={n} vol={vol_s} -> {category} (updated={rows_touched}){viol}")
        time.sleep(0.2)

    # Full run only: everything below the model gate (sum(abs(amount)) < 250
    # AND n < 10) never reaches the model — brief says these go straight to
    # needs_review, not worth the tokens. --limit runs skip this so a partial
    # dry-run doesn't blanket-mark the untouched residual.
    if LIMIT is None:
        psql_exec("""INSERT INTO _backup_u294_task5
                     SELECT id, category, category_source FROM bank_transactions
                      WHERE category IS NULL;
                     SELECT 'OK';""", "OK")
        small = psql("""
            UPDATE bank_transactions
               SET category = 'needs_review', category_confidence = 0,
                   category_source = '%s'
             WHERE category IS NULL
             RETURNING id;""" % CATEGORY_SOURCE)
        small_n = len(small)
        if small_n:
            total_updated += small_n
            totals["needs_review"] = totals.get("needs_review", 0) + small_n
        print(f"{datetime.now().isoformat()} sub-gate rows (below 250/10 threshold) "
              f"-> needs_review directly: {small_n}")

    print(f"{datetime.now().isoformat()} u294 T5 done: clusters={len(clusters)} "
          f"errors={errors} rows_updated={total_updated}")
    for cat, cnt in sorted(totals.items(), key=lambda kv: -kv[1]):
        print(f"  {cat}: {cnt}")
    print(f"OPS_ROWS={total_updated}")


if __name__ == "__main__":
    main()
