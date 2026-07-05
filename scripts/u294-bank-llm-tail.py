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

ALLOWED_SQL = """SELECT category FROM bank_category_registry
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
                  min_amt: str, max_amt: str, entity_id: str) -> str:
    cats_line = ", ".join(cats)
    samples_block = "\n".join(f"- {s}" for s in samples)
    personal_note = ""
    if entity_id in ("3", "4") and float(min_amt) < 0 and float(max_amt) < 0:
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
        personal_note,
        f"\nLines (same pattern, {n} rows, GBP total {vol}, amount range "
        f"{min_amt} to {max_amt}):\n",
        samples_block,
        '\nReturn ONLY JSON on one line, no other text: {"category": "...", "reason": "..."}',
    ]
    return "".join(parts)


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
    allowed = {r[0] for r in allowed_rows if r and r[0]}
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

        category = "needs_review"
        try:
            prompt = build_prompt(cats_list, n, vol_s, samples, min_amt, max_amt, entity_id)
            res = classify(prompt)
            cand = (res.get("category") or "").strip()
            if cand in allowed:
                category = cand
            else:
                category = "needs_review"
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

        print(f"CLUSTER {ckey} n={n} vol={vol_s} -> {category} (updated={rows_touched})")
        time.sleep(0.2)

    # Full run only: everything below the model gate (sum(abs(amount)) < 250
    # AND n < 10) never reaches the model — brief says these go straight to
    # needs_review, not worth the tokens. --limit runs skip this so a partial
    # dry-run doesn't blanket-mark the untouched residual.
    if LIMIT is None:
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
