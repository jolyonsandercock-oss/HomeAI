#!/usr/bin/env bash
#
# u235-embed-email-chunks.sh — Stage 1 of U235 cultural memory.
#
# Embeds every email_rag_chunks row into search_vectors via Ollama nomic-embed-text
# (768-dim, REAL[]). source_kind='email_chunk', source_id=chunk id, realm carried.
#
# Idempotent: only embeds chunks missing a (email_chunk, id, nomic-embed-text) row.
# Resumable: paginates by chunk id, so Ctrl-C / restart picks up where it left off.
# Retrieval-side note: query embeddings MUST use the "search_query: " prefix to match
# the "search_document: " prefix used here (nomic-embed-text v1.5 task prefixes).

set -euo pipefail

docker exec -i homeai-bot-responder python3 <<'PYEOF'
import asyncio, asyncpg, json, os, sys, time, urllib.request

OLLAMA_URL = "http://homeai-ollama:11434/api/embeddings"
MODEL      = "nomic-embed-text"
PAGE       = 2000        # rows fetched per DB round-trip (bounded memory)
LOG_EVERY  = 200


def vault_dsn():
    if dsn := os.environ.get("PG_DSN"):
        return dsn
    token = os.environ["VAULT_TOKEN"]
    req = urllib.request.Request("http://vault:8200/v1/secret/data/postgres",
                                 headers={"X-Vault-Token": token})
    data = json.loads(urllib.request.urlopen(req, timeout=5).read())
    pw = data["data"]["data"]["password"]
    return f"postgresql://postgres:{pw}@homeai-postgres:5432/homeai"


def embed(text):
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps({"model": MODEL, "prompt": "search_document: " + text}).encode(),
        headers={"Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=120)
    return json.loads(r.read()).get("embedding") or []


async def main():
    conn = await asyncpg.connect(vault_dsn())
    await conn.fetchval("SELECT set_config('app.current_entity', 'all',   false)")
    await conn.fetchval("SELECT set_config('app.current_realm',  'owner', false)")

    remaining = await conn.fetchval("""
        SELECT count(*) FROM email_rag_chunks c
        LEFT JOIN search_vectors s
          ON s.source_kind='email_chunk' AND s.source_id=c.id AND s.model=$1
        WHERE s.id IS NULL
    """, MODEL)
    print(f"[embed] {remaining} chunk(s) need embedding", flush=True)
    if not remaining:
        return

    t0, n_done, n_err, last_id = time.time(), 0, 0, 0
    while True:
        rows = await conn.fetch("""
            SELECT c.id, c.chunk_text, c.realm
            FROM email_rag_chunks c
            LEFT JOIN search_vectors s
              ON s.source_kind='email_chunk' AND s.source_id=c.id AND s.model=$1
            WHERE s.id IS NULL AND c.id > $2
            ORDER BY c.id
            LIMIT $3
        """, MODEL, last_id, PAGE)
        if not rows:
            break
        for row in rows:
            last_id = row["id"]
            text = (row["chunk_text"] or "").strip()
            if not text:
                continue
            try:
                vec = embed(text)
            except Exception as e:
                print(f"[embed] ERR chunk {row['id']}: {e}", file=sys.stderr, flush=True)
                n_err += 1
                continue
            if not vec:
                n_err += 1
                continue
            await conn.execute("""
                INSERT INTO search_vectors (source_kind, source_id, model, dim, embedding, text_snippet, realm)
                VALUES ('email_chunk', $1, $2, $3, $4::real[], $5, $6)
                ON CONFLICT (source_kind, source_id, model) DO NOTHING
            """, row["id"], MODEL, len(vec), vec, text, row["realm"] or "owner")
            n_done += 1
            if n_done % LOG_EVERY == 0:
                el = time.time() - t0
                rate = n_done / el if el else 0
                eta = (remaining - n_done) / rate if rate else 0
                print(f"[embed] {n_done}/{remaining}  ({rate:.1f}/s, ETA {eta/60:.1f}m)", flush=True)

    el = time.time() - t0
    print(f"[embed] DONE inserted={n_done} errors={n_err} elapsed={el/60:.1f}m", flush=True)
    await conn.close()


asyncio.run(main())
PYEOF
