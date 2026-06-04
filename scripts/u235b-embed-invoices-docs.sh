#!/usr/bin/env bash
#
# u235b-embed-invoices-docs.sh — Stage 1b of U235 cultural memory.
#
# Embeds invoice lines + OCR'd documents into search_vectors via nomic-embed-text,
# routed through home_ai.sanitise_full() (defence-in-depth; OCR/vendor text is
# external/untrusted). Reads v_research_corpus (the federated view u65 uses) but
# ONLY source_table IN ('invoice_line','document') — deliberately NOT the whole-email
# row (that path embeds RAW unsanitised body and is superseded by email_chunk).
#
# Idempotent on (source_kind, source_id, model); resumable by source_id pagination.
# Query embeddings MUST use the "search_query: " prefix to match "search_document: ".

set -euo pipefail

docker exec -i homeai-bot-responder python3 <<'PYEOF'
import asyncio, asyncpg, json, os, sys, time, urllib.request

OLLAMA_URL = "http://homeai-ollama:11434/api/embeddings"
MODEL      = "nomic-embed-text"
PAGE       = 1000
LOG_EVERY  = 200
MAX_CHARS  = 6000


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
    return json.loads(urllib.request.urlopen(req, timeout=120).read()).get("embedding") or []


async def main():
    conn = await asyncpg.connect(vault_dsn())
    await conn.fetchval("SELECT set_config('app.current_entity', 'all',   false)")
    await conn.fetchval("SELECT set_config('app.current_realm',  'owner', false)")

    for kind in ("invoice_line", "document"):
        remaining = await conn.fetchval("""
            SELECT count(*) FROM v_research_corpus v
            LEFT JOIN search_vectors s
              ON s.source_kind=v.source_table AND s.source_id=v.source_id AND s.model=$2
            WHERE v.source_table=$1 AND s.id IS NULL
        """, kind, MODEL)
        print(f"[embed:{kind}] {remaining} row(s) need embedding", flush=True)
        if not remaining:
            continue

        t0, n_done, n_err, last_id = time.time(), 0, 0, -1
        while True:
            rows = await conn.fetch("""
                SELECT v.source_id,
                       home_ai.sanitise_full(concat_ws(' ', v.title, v.body)) AS text,
                       v.realm
                FROM v_research_corpus v
                LEFT JOIN search_vectors s
                  ON s.source_kind=v.source_table AND s.source_id=v.source_id AND s.model=$2
                WHERE v.source_table=$1 AND s.id IS NULL AND v.source_id > $3
                ORDER BY v.source_id
                LIMIT $4
            """, kind, MODEL, last_id, PAGE)
            if not rows:
                break
            for row in rows:
                last_id = row["source_id"]
                text = (row["text"] or "").strip()[:MAX_CHARS]
                if not text:
                    continue
                try:
                    vec = embed(text)
                except Exception as e:
                    print(f"[embed:{kind}] ERR {row['source_id']}: {e}", file=sys.stderr, flush=True)
                    n_err += 1
                    continue
                if not vec:
                    n_err += 1
                    continue
                await conn.execute("""
                    INSERT INTO search_vectors (source_kind, source_id, model, dim, embedding, text_snippet, realm)
                    VALUES ($1, $2, $3, $4, $5::real[], $6, $7)
                    ON CONFLICT (source_kind, source_id, model) DO NOTHING
                """, kind, row["source_id"], MODEL, len(vec), vec, text[:500], row["realm"] or "work")
                n_done += 1
                if n_done % LOG_EVERY == 0:
                    el = time.time() - t0
                    rate = n_done / el if el else 0
                    print(f"[embed:{kind}] {n_done}/{remaining} ({rate:.1f}/s, ETA {(remaining-n_done)/rate/60:.1f}m)", flush=True)
        print(f"[embed:{kind}] DONE inserted={n_done} errors={n_err} elapsed={(time.time()-t0)/60:.1f}m", flush=True)

    await conn.close()


asyncio.run(main())
PYEOF
