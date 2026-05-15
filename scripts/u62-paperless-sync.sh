#!/usr/bin/env bash
# u62-paperless-sync.sh — pull new Paperless docs into the `documents`
# table, run the U61 entity-linker, and store the OCR text. Cron */15.

set -euo pipefail

VT=$(docker inspect homeai-bot-responder --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PL_USER="jo"
PL_PASS=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=admin_password secret/paperless)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"

docker exec -i -e PG_DSN="$PG_DSN" -e PL_USER="$PL_USER" -e PL_PASS="$PL_PASS" \
    homeai-bot-responder python /dev/stdin <<'PYEOF'
import os, asyncio, re, hashlib
import httpx, asyncpg

PL_BASE = "http://homeai-paperless:8000"
PG_DSN = os.environ["PG_DSN"]
PL_USER = os.environ["PL_USER"]
PL_PASS = os.environ["PL_PASS"]
PLATE_RE = re.compile(r"\b([A-Z]{2}\s?\d{2}\s?[A-Z]{3})\b")

async def login(client):
    r = await client.post(f"{PL_BASE}/api/token/",
                          json={"username": PL_USER, "password": PL_PASS})
    r.raise_for_status()
    return r.json()["token"]

async def link(conn, ocr_text):
    haystack = (ocr_text or "").upper()
    for m in PLATE_RE.finditer(haystack):
        plate = re.sub(r"\s+", "", m.group(1))
        veh = await conn.fetchrow(
            "SELECT id, entity_id FROM vehicles "
            "WHERE upper(replace(registration,' ','')) = $1 LIMIT 1", plate)
        if veh:
            return ("vehicles", veh["id"], "auto:plate_regex", veh["entity_id"])
    return (None, None, None, None)

async def insert_doc(conn, **kw):
    # AGENTS.md SQL discipline: SET LOCAL inside the transaction containing
    # the INSERT into the RLS-scoped documents table.
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = 'all'")
        await conn.execute("SELECT home_ai.set_realm('owner')")
        await conn.execute("""
            INSERT INTO documents
                (paperless_id, entity_id, category, title, status,
                 file_path, mime_type, sha256, ocr_text,
                 linked_table, linked_id, linked_by, uploaded_by, realm)
            VALUES ($1, $2, $3, $4, 'active',
                    $5, $6, $7, $8,
                    $9, $10, $11, 'paperless',
                    'family')
            ON CONFLICT (paperless_id) DO NOTHING
        """, kw["pl_id"], kw["eid"], kw["category"], kw["title"],
             kw["path"], kw["mime"], kw["sha"], kw["ocr"],
             kw["ltbl"], kw["lid"], kw["lby"])

async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")
    await conn.execute("SET app.current_realm  = 'owner'")
    last_seen = await conn.fetchval(
        "SELECT COALESCE(MAX(paperless_id), 0) FROM documents WHERE paperless_id IS NOT NULL")
    print(f"last paperless_id seen: {last_seen}")

    async with httpx.AsyncClient(timeout=60) as client:
        token = await login(client)
        H = {"Authorization": f"Token {token}"}
        ingested = 0
        page = 1
        while True:
            r = await client.get(f"{PL_BASE}/api/documents/",
                                 headers=H,
                                 params={"page": page, "page_size": 100,
                                         "id__gt": last_seen,
                                         "ordering": "id"})
            r.raise_for_status()
            j = r.json()
            for doc in j.get("results", []):
                pl_id = doc["id"]
                title = doc.get("title") or f"paperless_{pl_id}"
                ocr   = doc.get("content") or ""
                tag_names = doc.get("tag_names") or []
                tags  = ", ".join(t["name"] for t in tag_names) if tag_names else ""
                fr = await client.get(f"{PL_BASE}/api/documents/{pl_id}/download/",
                                       headers=H, follow_redirects=True)
                fr.raise_for_status()
                sha  = hashlib.sha256(fr.content).hexdigest()
                path = f"/home_ai/storage/documents/{sha}.pdf"
                if not os.path.exists(path):
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    with open(path, "wb") as f:
                        f.write(fr.content)
                ltbl, lid, lby, eid = await link(conn, ocr + " " + title)
                await insert_doc(conn,
                    pl_id=pl_id, eid=eid, category=(tags or 'paperless'),
                    title=title[:200], path=path, mime="application/pdf",
                    sha=sha, ocr=ocr, ltbl=ltbl, lid=lid, lby=lby)
                ingested += 1
            if not j.get("next"):
                break
            page += 1
        print(f"ingested {ingested} new documents from Paperless")

    await conn.close()

asyncio.run(main())
PYEOF
