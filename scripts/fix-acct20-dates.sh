#!/usr/bin/env bash
# fix-acct20-dates.sh — DATE-ONLY correction for account 20 (Dojo settlement 48885525).
#
# Account 20's DB rows (atr20_validated_v1) have GOOD amounts (sign-correct) but
# partially-collapsed dates. The extract NW-48885525.csv has real dates + the same
# authoritative balances but BAD amounts (extract has gaps/sign errors). So we take
# the real DATE from the extract via unique BALANCE match and UPDATE only the date,
# leaving the good amounts untouched. Rows whose balance is ambiguous (e.g. the many
# 0.01 sweep-empties) or absent in the extract keep their current date (reported).
#
#   fix-acct20-dates.sh [--apply]
# Default = DRY RUN (reports how many dates would change, writes nothing).
# --apply snapshots public._backup_atr20_dates(id,old_date) then UPDATEs in one txn.
set -euo pipefail
APPLY="${1:-}"
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"
unset VT PG_PW
CTR=/tmp/fix20-$$
docker exec homeai-bot-responder mkdir -p "$CTR"
docker cp storage/extracted/NW-48885525.csv "homeai-bot-responder:$CTR/ext.csv"

docker exec -i -e PG_DSN="$PG_DSN" -e CSV="$CTR/ext.csv" -e APPLY="$APPLY" homeai-bot-responder python <<'PYEOF'
import asyncio, asyncpg, os, csv, re
from datetime import datetime
from collections import defaultdict
def pbal(s):
    s=(s or "").replace(",","").strip()
    try: return round(float(s),2)
    except: return None
async def main():
    # balance -> set of real dates from the extract (txn rows only)
    bal2dates=defaultdict(set)
    for r in csv.DictReader(open(os.environ["CSV"],newline="",encoding="utf-8-sig")):
        if not ((r.get("paid_in") or "").strip() or (r.get("paid_out") or "").strip()): continue
        b=pbal(r["balance"])
        if b is None: continue
        try: d=datetime.strptime(r["date"].strip(),"%d %b %Y").date()
        except: continue
        bal2dates[b].add(d)
    c=await asyncpg.connect(os.environ["PG_DSN"])
    await c.execute("SELECT set_config('app.current_entity','all',false)")
    await c.execute("SELECT home_ai.set_realm('owner')")
    rows=await c.fetch("SELECT id, transaction_date, balance FROM bank_transactions WHERE bank_account_id=20 AND source='atr20_validated_v1' ORDER BY id")
    updates=[]; ambiguous=nomatch=already=0
    for r in rows:
        b=round(float(r["balance"]),2) if r["balance"] is not None else None
        ds=bal2dates.get(b) if b is not None else None
        if not ds: nomatch+=1; continue
        if len(ds)>1: ambiguous+=1; continue
        real=next(iter(ds))
        if real==r["transaction_date"]: already+=1
        else: updates.append((r["id"], real))
    print(f"acct20 date-fix: {len(rows)} rows | would-change={len(updates)} already-correct={already} ambiguous={ambiguous} nomatch={nomatch}")
    if os.environ["APPLY"]!="--apply":
        for i,d in updates[:8]: print(f"   sample: id={i} -> {d}")
        await c.close(); return
    async with c.transaction():
        await c.execute("DROP TABLE IF EXISTS public._backup_atr20_dates")
        await c.execute("CREATE TABLE public._backup_atr20_dates (id bigint, old_date date)")
        for i,d in updates:
            await c.execute("INSERT INTO public._backup_atr20_dates VALUES ($1,(SELECT transaction_date FROM bank_transactions WHERE id=$1))",i)
            await c.execute("UPDATE bank_transactions SET transaction_date=$2 WHERE id=$1",i,d)
        print(f"APPLIED: {len(updates)} dates corrected (old dates backed up to public._backup_atr20_dates)")
    await c.close()
asyncio.run(main())
PYEOF
docker exec homeai-bot-responder rm -rf "$CTR"
