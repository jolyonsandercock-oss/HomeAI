#!/bin/bash
# u84-bulk-reclassify-shared.sh
#
# Re-OCR every 'shared'-tagged vendor_invoice_inbox row that has a local PDF,
# cache the extracted text into pdf_text_extracted, and let the V108 trigger
# automatically reclassify site (cafe / pub / shared) based on body+PDF
# markers (MAL125 → cafe, TOM106 → pub).
#
# Idempotent: safe to re-run. Rows already populated are skipped.
#
# Usage:
#   bash /home_ai/scripts/u84-bulk-reclassify-shared.sh [LIMIT]
#   LIMIT defaults to 500. Run a few times to drain the backlog.

set -euo pipefail
LIMIT="${1:-500}"

echo "── u84 bulk reclassifier — limit=$LIMIT"

docker exec -i -e LIMIT="$LIMIT" homeai-build-dashboard python <<'PYEOF'
import os, asyncio, asyncpg, httpx, time

PG_DSN = os.environ["PG_DSN"]
LIMIT  = int(os.environ.get("LIMIT", "500"))
PDF_SVC = "http://homeai-pdfplumber:8003/extract-pdf"

async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SELECT home_ai.set_realm('owner')")

    rows = await conn.fetch(f"""
        SELECT id, pdf_local_path
          FROM vendor_invoice_inbox
         WHERE (site IS NULL OR site = 'shared')
           AND pdf_local_path IS NOT NULL
           AND pdf_text_extracted IS NULL
         ORDER BY id DESC
         LIMIT {LIMIT}
    """)
    print(f"candidates: {len(rows)}")
    if not rows:
        await conn.close()
        return

    stats = {"ok": 0, "fail": 0, "cafe": 0, "pub": 0, "shared": 0,
             "t0": time.time()}

    async with httpx.AsyncClient(timeout=60) as client:
        for r in rows:
            inv_id = r["id"]
            try:
                with open(r["pdf_local_path"], "rb") as f:
                    resp = await client.post(
                        PDF_SVC,
                        files={"file": (f"{inv_id}.pdf", f, "application/pdf")},
                    )
                if resp.status_code != 200:
                    stats["fail"] += 1
                    print(f"  #{inv_id}: pdfplumber {resp.status_code}")
                    continue
                text = (resp.json() or {}).get("text") or ""
            except Exception as e:
                stats["fail"] += 1
                print(f"  #{inv_id}: {e}")
                continue

            # Truncate ridiculously large PDFs (statements etc) at 100KB chars
            text = text[:100_000]

            # Write back. The V108 trigger fires on UPDATE OF pdf_text_extracted
            # so site reclassifies inside this single statement.
            new_site = await conn.fetchval("""
                UPDATE vendor_invoice_inbox
                   SET pdf_text_extracted    = $1,
                       pdf_text_extracted_at = now()
                 WHERE id = $2
                 RETURNING site
            """, text, inv_id)

            stats["ok"] += 1
            if new_site in stats:
                stats[new_site] += 1
            if stats["ok"] % 25 == 0:
                rate = stats["ok"] / max(1, time.time() - stats["t0"])
                print(f"  …{stats['ok']}/{len(rows)} "
                      f"cafe={stats['cafe']} pub={stats['pub']} shared={stats['shared']} "
                      f"({rate:.1f}/s)")

    await conn.close()
    dur = time.time() - stats["t0"]
    print()
    print(f"=== Summary (took {dur:.0f}s) ===")
    for k, v in stats.items():
        if k != "t0":
            print(f"  {k:8s} = {v}")

asyncio.run(main())
PYEOF
