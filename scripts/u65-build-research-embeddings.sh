#!/usr/bin/env bash
#
# u65-build-research-embeddings.sh — populate search_vectors via Ollama.
#
# Pulls every v_research_corpus row that doesn't yet have an embedding,
# calls qwen2.5:7b at homeai-ollama:11434/api/embeddings, stores the
# 3584-dim float vector as REAL[] in search_vectors.
#
# Idempotent: only processes rows where (source_kind, source_id, model) is
# missing. Batch-safe — bails cleanly on Ctrl-C, picks up where it left off.

set -euo pipefail

docker exec -i homeai-bot-responder python3 <<'PYEOF'
import asyncio, asyncpg, json, os, sys, time, urllib.request, urllib.error

OLLAMA_URL = "http://homeai-ollama:11434/api/embeddings"
MODEL      = "nomic-embed-text"
BATCH_SIZE = 25
MAX_CHARS  = 6000


def vault_dsn():
    if dsn := os.environ.get("PG_DSN"):
        return dsn
    token = os.environ["VAULT_TOKEN"]
    req = urllib.request.Request(
        "http://vault:8200/v1/secret/data/postgres",
        headers={"X-Vault-Token": token})
    data = json.loads(urllib.request.urlopen(req, timeout=5).read())
    pw = data["data"]["data"]["password"]
    return f"postgresql://postgres:{pw}@homeai-postgres:5432/homeai"


def embed(text):
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps({"model": MODEL, "prompt": text}).encode(),
        headers={"Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=120)
    return json.loads(r.read()).get("embedding") or []


async def main():
    conn = await asyncpg.connect(vault_dsn())
    await conn.fetchval("SELECT set_config('app.current_entity', 'all',   false)")
    await conn.fetchval("SELECT set_config('app.current_realm',  'owner', false)")

    todo = await conn.fetch(f"""
      SELECT v.source_table AS source_kind, v.source_id, v.title, v.body, v.realm
        FROM v_research_corpus v
        LEFT JOIN search_vectors s
          ON s.source_kind = v.source_table
         AND s.source_id   = v.source_id
         AND s.model       = '{MODEL}'
       WHERE s.id IS NULL
       ORDER BY v.event_at DESC NULLS LAST
    """)
    print(f"[embed] {len(todo)} corpus row(s) need embedding")
    if not todo:
        return

    t0, n_done, n_err = time.time(), 0, 0
    for row in todo:
        title = (row["title"] or "").strip()
        body  = (row["body"]  or "").strip()
        text  = f"{title}\n\n{body}".strip()[:MAX_CHARS]
        if not text:
            continue
        # nomic-embed-text v1.5: document-side prefix for sharp retrieval.
        prefixed = "search_document: " + text
        try:
            vec = embed(prefixed)
        except Exception as e:
            print(f"[embed] ERR {row['source_kind']}:{row['source_id']} {e}", file=sys.stderr)
            n_err += 1
            continue
        if not vec:
            n_err += 1
            continue
        await conn.execute("""
            INSERT INTO search_vectors (source_kind, source_id, model, dim, embedding, text_snippet, realm)
            VALUES ($1, $2, $3, $4, $5::real[], $6, $7)
            ON CONFLICT (source_kind, source_id, model) DO NOTHING
        """, row["source_kind"], row["source_id"], MODEL, len(vec),
             vec, text[:300], row["realm"] or "owner")
        n_done += 1
        if n_done % BATCH_SIZE == 0:
            el = time.time() - t0
            rate = n_done / el if el > 0 else 0
            eta = (len(todo) - n_done) / rate if rate > 0 else 0
            print(f"[embed] {n_done}/{len(todo)}  ({rate:.1f}/s, ETA {eta:.0f}s)")

    el = time.time() - t0
    print(f"[embed] done. inserted={n_done} errors={n_err} elapsed={el:.0f}s")
    await conn.close()


asyncio.run(main())
PYEOF
