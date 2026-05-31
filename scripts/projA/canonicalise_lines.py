#!/usr/bin/env python3
"""Canonicalise purchase_lines.description → product_canonical (family + name).

Pipeline per distinct description:
  1. exact alias-cache hit (product_aliases.raw_text) — free
  2. else Haiku batch maps it to {family, canonical_name}, reusing the existing
     taxonomy where it fits ('Buttermilk' is milk, 'mashed potato with butter' is
     potato — generic product, not brand/pack)
  3. find-or-create product_canonical, write a product_alias, back-fill every
     purchase_line with that description.

Runs in homeai-bot-responder. Usage: python3 canonicalise_lines.py [--limit N] [--max-cloud-usd U]
"""
from __future__ import annotations
import os, sys, json, urllib.request, asyncio, argparse, time
PG_DSN = os.environ["PG_DSN"]
HAIKU  = "claude-haiku-4-5-20251001"
BATCH  = 25
ALLOWED_FAMILIES = {'milk','wine','beer','spirits','soft_drink','tea','coffee','tea_coffee',
    'meat','fish','veg','fruit','dairy_other','cheese','bakery','bread_bakery','packaging',
    'cleaning','fuel','condiment','condiments','dry_goods','frozen','ice_cream_flavour',
    'utility','service','equipment','software','sundry'}


def vault(p):
    req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                  headers={"X-Vault-Token": os.environ["VAULT_TOKEN"]})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


SYS = ("Map each UK supplier invoice line to a canonical grocery/drink product. "
       "Return the GENERIC product, never the brand or pack size: 'Meadowchurn Butter "
       "Salted 40'→family butter, name 'Salted butter'; '11 GUINNESS'→family beer, name "
       "'Guinness'; 'Trewithen Cornish Semi Skimmed Milk'→family milk, name 'Semi-skimmed "
       "milk'. Watch traps: 'Buttermilk'→family milk (NOT butter); 'Mashed potato with "
       "butter'→family potato (NOT butter). Reuse an existing family/name when it fits. "
       "Non-products (delivery, discount, charge) → family 'sundry', name 'Other'. "
       "family MUST be exactly one of: milk, wine, beer, spirits, soft_drink, tea, coffee, "
       "tea_coffee, meat, fish, veg, fruit, dairy_other, cheese, bakery, bread_bakery, "
       "packaging, cleaning, fuel, condiment, dry_goods, frozen, ice_cream_flavour, utility, "
       "service, equipment, software, sundry. Butter→dairy_other; herbs/potato→veg.")

TOOL = {"name": "map_products", "description": "Canonicalise each line.",
        "input_schema": {"type": "object", "properties": {"items": {"type": "array", "items": {
            "type": "object", "properties": {
                "i": {"type": "integer"},
                "family": {"type": "string"},
                "name": {"type": "string"}},
            "required": ["i", "family", "name"]}}}, "required": ["items"]}}


def classify_batch(client, descs, taxonomy, state):
    prompt = ("Existing canonical products (family · name) — reuse where they fit:\n"
              + "\n".join(f"- {f} · {n}" for f, n in taxonomy[:120])
              + "\n\nClassify these invoice lines (return one item per index):\n"
              + "\n".join(f"{i}. {d}" for i, d in enumerate(descs)))
    try:
        r = client.messages.create(model=HAIKU, max_tokens=2000, system=SYS, tools=[TOOL],
            tool_choice={"type": "tool", "name": "map_products"},
            messages=[{"role": "user", "content": prompt}])
    except Exception as e:
        sys.stderr.write(f"batch err: {str(e)[:120]}\n"); return {}
    state["in_tok"] += r.usage.input_tokens; state["out_tok"] += r.usage.output_tokens
    state["cloud_usd"] += r.usage.input_tokens / 1e6 + r.usage.output_tokens * 5 / 1e6
    tu = [b for b in r.content if b.type == "tool_use"]
    if not tu: return {}
    out = {}
    for it in tu[0].input.get("items", []):
        if isinstance(it.get("i"), int) and 0 <= it["i"] < len(descs):
            fam = str(it.get("family", "sundry")).strip().lower()
            if fam not in ALLOWED_FAMILIES: fam = 'sundry'
            out[it["i"]] = (fam, str(it.get("name", "Other")).strip()[:80] or "Other")
    return out


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)   # distinct descriptions; 0 = all
    ap.add_argument("--max-cloud-usd", type=float, default=5.0)
    args = ap.parse_args()
    import asyncpg, anthropic
    client = anthropic.Anthropic(api_key=vault("anthropic")["api_key"])
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_realm='owner'")

    # in-memory caches
    canon = {}   # name_lower -> id
    for r in await conn.fetch("SELECT id, family, name FROM product_canonical"):
        canon[r["name"].lower()] = r["id"]
    taxonomy = [(r["family"], r["name"]) for r in await conn.fetch("SELECT DISTINCT family, name FROM product_canonical ORDER BY family, name")]
    alias = {}   # raw_lower -> canonical_id
    for r in await conn.fetch("SELECT lower(raw_text) rt, canonical_id FROM product_aliases"):
        alias[r["rt"]] = r["canonical_id"]

    lim = "" if args.limit == 0 else f"LIMIT {args.limit}"
    rows = await conn.fetch(f"""
      SELECT lower(description) d, count(*) n FROM purchase_lines
      WHERE product_canonical_id IS NULL AND description IS NOT NULL AND length(trim(description))>1
      GROUP BY 1 ORDER BY 2 DESC {lim}
    """)
    descs = [r["d"] for r in rows]
    print(f"distinct descriptions: {len(descs)}", flush=True)

    state = {"in_tok": 0, "out_tok": 0, "cloud_usd": 0.0, "matched_alias": 0,
             "classified": 0, "new_canon": 0, "lines_updated": 0}

    async def assign(desc, cid):
        if desc not in alias:
            await conn.execute("INSERT INTO product_aliases (canonical_id, raw_text, confidence, confirmed_by, realm) VALUES ($1,$2,$3,'ai','shared')",
                               cid, desc, 0.8)
            alias[desc] = cid
        res = await conn.execute("UPDATE purchase_lines SET product_canonical_id=$1 WHERE lower(description)=$2 AND product_canonical_id IS NULL", cid, desc)
        try: state["lines_updated"] += int(res.split()[-1])
        except Exception: pass

    # pass 1: alias cache
    todo = []
    for d in descs:
        if d in alias:
            await assign(d, alias[d]); state["matched_alias"] += 1
        else:
            todo.append(d)

    # pass 2: Haiku batches
    for i in range(0, len(todo), BATCH):
        if state["cloud_usd"] >= args.max_cloud_usd:
            print(f"ceiling hit at ${state['cloud_usd']:.3f}", flush=True); break
        batch = todo[i:i + BATCH]
        mapping = classify_batch(client, batch, taxonomy, state)
        for j, d in enumerate(batch):
            fam, name = mapping.get(j, ("other", "Other"))
            cid = canon.get(name.lower())
            if cid is None:
                cid = await conn.fetchval("INSERT INTO product_canonical (family, name, realm) VALUES ($1,$2,'shared') RETURNING id", fam, name)
                canon[name.lower()] = cid; state["new_canon"] += 1
            await assign(d, cid); state["classified"] += 1
        if (i // BATCH) % 5 == 0:
            print(f"  {i+len(batch)}/{len(todo)} classified, ${state['cloud_usd']:.3f}", flush=True)

    await conn.close()
    print("\n== canonicalise ==")
    for k in ("matched_alias", "classified", "new_canon", "lines_updated"):
        print(f"  {k:14} {state[k]}")
    print(f"  cloud_usd      ${state['cloud_usd']:.4f}")

if __name__ == "__main__":
    asyncio.run(main())
