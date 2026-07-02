#!/usr/bin/env bash
# u-natwest-inbox-sweep.sh — auto-import NatWest CSVs dropped into
# data/natwest-inbox/ by u33-data-lane-router (emailed bank statements).
# Mirrors u135-dojo-inbox-sweep: scoop new CSVs → idempotent import into
# bank_transactions → archive to processed/ → log file_sha256 to `imports`.
#
# DEDUP (no duplication risk, two layers):
#   row-level : bank_transactions.idempotency_key UNIQUE + ON CONFLICT DO NOTHING
#               (key = sha256(account_number|date|value|balance|description))
#   file-level: a file already in `imports` (by file_sha256) is SKIPPED, and
#               processed files move to ./processed/ so they're never re-swept.
# Account→entity mapping comes from bank_accounts (NOT hardcoded).
# RLS: sets app.current_entity='all' + realm='owner' (cross-realm admin import);
# each row's realm/entity is written explicitly from bank_accounts.
set -euo pipefail
INBOX="/home_ai/data/natwest-inbox"
ARCHIVE="$INBOX/processed"
mkdir -p "$ARCHIVE"
CTR_DIR="/tmp/nw-sweep-$$"

VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"
unset VT PG_PW

mapfile -t CSVS < <(find "$INBOX" -name '*.csv' -not -path "$ARCHIVE/*" 2>/dev/null)
[ "${#CSVS[@]}" -eq 0 ] && { echo "$(date -Is) no new NatWest CSVs"; exit 0; }

docker exec homeai-bot-responder mkdir -p "$CTR_DIR"
# Per-item degrade: a single failed docker cp must not abort the whole sweep
# (set -e would otherwise kill the loop on the first bad file) — but a
# skipped file must ALSO be excluded from the archive loop below, or it gets
# moved to processed/ without ever having been imported (data loss). Track
# successes/failures explicitly rather than reusing CSVS for both purposes.
COPIED=(); SKIPPED=()
for f in "${CSVS[@]}"; do
  if docker cp "$f" "homeai-bot-responder:$CTR_DIR/$(basename "$f")" 2>/dev/null; then
    COPIED+=("$f")
  else
    SKIPPED+=("$f")
    echo "$(date -Is) WARN docker cp failed, leaving in inbox for retry: $f" >&2
  fi
done
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  echo "$(date -Is) ${#SKIPPED[@]} file(s) failed docker cp — left in inbox for retry: ${SKIPPED[*]}"
fi
if [ "${#COPIED[@]}" -eq 0 ]; then
  echo "$(date -Is) no CSVs successfully copied — nothing to import"
  exit 1
fi

if docker exec -i -e PG_DSN="$PG_DSN" -e CSV_DIR="$CTR_DIR" homeai-bot-responder python <<'PYEOF'
import asyncio, asyncpg, os, csv, glob, hashlib
from datetime import datetime
CSV_DIR=os.environ["CSV_DIR"]
def parse_date(s):
    for fmt in ("%d %b %Y","%d/%m/%Y","%Y-%m-%d"):
        try: return datetime.strptime(s.strip(), fmt).date()
        except: pass
    return None
async def main():
    c=await asyncpg.connect(os.environ["PG_DSN"])
    # RLS context: cross-realm admin import (both GUCs — see RLS-GUC discipline).
    await c.execute("SELECT set_config('app.current_entity','all',false)")
    await c.execute("SELECT home_ai.set_realm('owner')")
    amap={}
    for r in await c.fetch("SELECT id,entity_id,realm,account_number,sort_code FROM bank_accounts"):
        acct=str(r["account_number"]); sc=str(r["sort_code"] or "")
        v=(r["id"],r["entity_id"],r["realm"]); amap[acct]=v
        if sc: amap[f"{sc}-{acct}"]=v; amap[f"{sc.replace('-','')}-{acct}"]=v
    total_new=0; files=0; skipped=0
    for path in sorted(glob.glob(CSV_DIR+"/*.csv")):
        raw=open(path,"rb").read(); fsha=hashlib.sha256(raw).hexdigest()
        if await c.fetchval("SELECT 1 FROM raw.imports WHERE file_sha256=$1",fsha):
            skipped+=1; print(f"  SKIP already-ingested: {os.path.basename(path)}"); continue
        files+=1; seen=0
        with open(path, newline="", encoding="utf-8-sig") as fh:
            for row in csv.DictReader(fh):
                acctnum=(row.get("Account Number") or "").strip()
                m=amap.get(acctnum) or amap.get(acctnum.replace("-","")) or amap.get(acctnum.split("-")[-1])
                if not m: continue
                ba_id,ent,realm=m
                d=parse_date(row.get("Date","")); val=row.get("Value","").strip(); bal=row.get("Balance","").strip()
                desc=(row.get("Description") or "").strip()
                if d is None or not val: continue
                key=hashlib.sha256(f"{acctnum}|{d}|{val}|{bal}|{desc}".encode()).hexdigest()[:32]
                res=await c.execute("""INSERT INTO bank_transactions
                    (idempotency_key,bank_account_id,entity_id,transaction_date,description,amount,balance,source,realm)
                    SELECT $1,$2,$3,$4,$5,$6::numeric,$7::numeric,'natwest_csv',$8 WHERE NOT EXISTS (SELECT 1 FROM bank_transactions b WHERE b.bank_account_id=$2 AND b.transaction_date=$4 AND b.amount=$6::numeric AND b.description IS NOT DISTINCT FROM $5)
                    ON CONFLICT (idempotency_key) DO NOTHING""",
                    key,ba_id,ent,d,desc,val.replace(",",""),(bal.replace(",","") or None),realm)
                if res.endswith("1"): total_new+=1
                seen+=1
        await c.execute("INSERT INTO raw.imports (source,adapter,file_sha256,payload_path,manifest_json,captured_at,row_count,imported_at,operator,realm) VALUES ('natwest_csv','csv',$1,$2,'{}'::jsonb,now(),$3,now(),'cron','owner')",fsha,os.path.basename(path),seen)
        print(f"  {os.path.basename(path)}: {seen} rows seen")
    print(f"NatWest sweep: {files} new file(s), {skipped} already-ingested, {total_new} NEW transactions")
    await c.close()
asyncio.run(main())
PYEOF
then
  rc=0
else
  rc=$?
fi
docker exec homeai-bot-responder rm -rf "$CTR_DIR" 2>/dev/null || true
if [ "$rc" -eq 0 ]; then
  # Archive only files that were actually copied in (and thus imported) —
  # never CSVS, which may include files skipped above.
  for f in "${COPIED[@]}"; do mv "$f" "$ARCHIVE/$(date +%Y%m%d-%H%M%S)-$(basename "$f")" 2>/dev/null || true; done
  echo "$(date -Is) archived ${#COPIED[@]} file(s) → $ARCHIVE"
fi
# Surface partial cp failures as a degraded (nonzero) run even if the import
# itself succeeded, so cron-health flags it instead of silently retrying forever.
if [ "${#SKIPPED[@]}" -gt 0 ] && [ "$rc" -eq 0 ]; then
  rc=1
fi
exit $rc
