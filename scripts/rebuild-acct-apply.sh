#!/usr/bin/env bash
# rebuild-acct-apply.sh — APPLY a balance-chain reconstruction of one bank account.
# Reversible: snapshots old rows + dependent transfers into public._backup_* tables
# inside the same transaction before deleting. See rebuild-bank-from-balance-chain.py
# for the reconstruction rationale (balance-delta = ground-truth amount).
#
#   rebuild-acct-apply.sh <account_id> <csv_path> <old_source> <new_source> <cutoff_iso>
# Inserts reconstructed rows with transaction_date < cutoff_iso (later coverage is
# left to whatever already exists, e.g. natwest_csv). entity_id/realm read from bank_accounts.
set -euo pipefail
ACCT="$1"; CSV="$2"; OLD_SRC="$3"; NEW_SRC="$4"; CUTOFF="$5"
[ -f "$CSV" ] || { echo "no csv: $CSV"; exit 1; }

VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"
unset VT PG_PW

CTR=/tmp/rebuild-$$
docker exec homeai-bot-responder mkdir -p "$CTR"
docker cp "$CSV" "homeai-bot-responder:$CTR/extract.csv"

docker exec -i -e PG_DSN="$PG_DSN" -e ACCT="$ACCT" -e OLD_SRC="$OLD_SRC" -e NEW_SRC="$NEW_SRC" \
  -e CUTOFF="$CUTOFF" -e CSV="$CTR/extract.csv" homeai-bot-responder python <<'PYEOF'
import asyncio, asyncpg, os, csv, hashlib
from datetime import datetime, date
from collections import OrderedDict
ACCT=int(os.environ["ACCT"]); OLD=os.environ["OLD_SRC"]; NEW=os.environ["NEW_SRC"]
CUTOFF=datetime.strptime(os.environ["CUTOFF"],"%Y-%m-%d").date()
def pbal(s):
    s=(s or "").replace(",","").strip()
    try: return round(float(s),2)
    except: return None
def ppaid(r):
    pi=(r.get("paid_in") or "").replace(",","").strip(); po=(r.get("paid_out") or "").replace(",","").strip()
    v=0.0
    if pi: v+=float(pi)
    if po: v-=float(po)
    return round(v,2)
def reconstruct(path):
    rows=list(csv.DictReader(open(path,newline="",encoding="utf-8-sig")))
    bystmt=OrderedDict()
    for r in rows: bystmt.setdefault(r["source_file"],[]).append(r)
    led=[]
    for sf,rs in bystmt.items():
        prev=None
        for r in rs:
            b=pbal(r["balance"]); has=bool((r.get("paid_in") or "").strip() or (r.get("paid_out") or "").strip())
            if not has:
                if b is not None: prev=b
                continue
            if b is None: continue
            amt=ppaid(r) if prev is None else round(b-prev,2)
            try: d=datetime.strptime(r["date"].strip(),"%d %b %Y").date()
            except: prev=b; continue
            desc=" ".join((r["description"] or "").split())[:500]
            led.append((d,desc,amt,b)); prev=b
    # content-dedup boundary overlaps
    seen=set(); out=[]
    for t in led:
        k=(t[0],t[2],t[1])
        if k in seen: continue
        seen.add(k); out.append(t)
    return out

async def main():
    led=reconstruct(os.environ["CSV"])
    led=[t for t in led if t[0] < CUTOFF]   # later coverage left to existing rows
    c=await asyncpg.connect(os.environ["PG_DSN"])
    await c.execute("SELECT set_config('app.current_entity','all',false)")
    await c.execute("SELECT home_ai.set_realm('owner')")
    ent_realm=await c.fetchrow("SELECT entity_id, realm FROM bank_accounts WHERE id=$1",ACCT)
    ent,realm=ent_realm["entity_id"],ent_realm["realm"]
    async with c.transaction():
        # 1. snapshot (reversible)
        await c.execute(f"DROP TABLE IF EXISTS public._backup_{OLD}_rows")
        await c.execute(f"CREATE TABLE public._backup_{OLD}_rows AS SELECT * FROM bank_transactions WHERE bank_account_id=$1 AND source=$2",ACCT,OLD)
        await c.execute(f"DROP TABLE IF EXISTS public._backup_{OLD}_transfers")
        await c.execute(f"""CREATE TABLE public._backup_{OLD}_transfers AS
            SELECT at.* FROM account_transfers at WHERE at.src_txn_id IN (SELECT id FROM bank_transactions WHERE bank_account_id=$1)
            OR at.dst_txn_id IN (SELECT id FROM bank_transactions WHERE bank_account_id=$1)""",ACCT)
        nb_rows=await c.fetchval(f"SELECT count(*) FROM public._backup_{OLD}_rows")
        nb_tr=await c.fetchval(f"SELECT count(*) FROM public._backup_{OLD}_transfers")
        # 2. delete dependent transfers, then old collapsed rows
        await c.execute("""DELETE FROM account_transfers WHERE src_txn_id IN (SELECT id FROM bank_transactions WHERE bank_account_id=$1 AND source=$2)
            OR dst_txn_id IN (SELECT id FROM bank_transactions WHERE bank_account_id=$1 AND source=$2)""",ACCT,OLD)
        deld=await c.execute("DELETE FROM bank_transactions WHERE bank_account_id=$1 AND source=$2",ACCT,OLD)
        # 3. insert reconstructed ledger, content-dedup vs any remaining rows (e.g. natwest_csv)
        ins=0
        for d,desc,amt,bal in led:
            key=hashlib.sha256(f"balrecon|{ACCT}|{d}|{amt:.2f}|{bal:.2f}|{desc}".encode()).hexdigest()[:32]
            res=await c.execute("""INSERT INTO bank_transactions
                (idempotency_key,bank_account_id,entity_id,transaction_date,description,amount,balance,source,realm)
                SELECT $1,$2,$3,$4,$5,$6::numeric,$7::numeric,$8,$9
                WHERE NOT EXISTS (SELECT 1 FROM bank_transactions b WHERE b.bank_account_id=$2 AND b.transaction_date=$4 AND b.amount=$6::numeric AND b.description IS NOT DISTINCT FROM $5)
                ON CONFLICT (idempotency_key) DO NOTHING""",
                key,ACCT,ent,d,desc,amt,bal,NEW,realm)
            if res.endswith("1"): ins+=1
        # 4. fix sort code (extract + bank confirm 600001)
        await c.execute("UPDATE bank_accounts SET sort_code='600001' WHERE id=$1 AND sort_code<>'600001'",ACCT)
        # 5. provenance
        await c.execute("""INSERT INTO raw.imports (source,adapter,file_sha256,payload_path,manifest_json,captured_at,row_count,imported_at,operator,realm)
            VALUES ($1,'csv',$2,$3,'{}'::jsonb,now(),$4,now(),'rebuild-balance-chain','owner')""",
            NEW, hashlib.sha256(NEW.encode()).hexdigest(), os.path.basename(os.environ["CSV"]), ins)
        print(f"snapshot: {nb_rows} rows + {nb_tr} transfers backed up")
        print(f"deleted old source: {deld}; deleted dependent transfers")
        print(f"inserted reconstructed (date<{CUTOFF}): {ins} rows  source={NEW}")
    await c.close()
asyncio.run(main())
PYEOF
docker exec homeai-bot-responder rm -rf "$CTR"
