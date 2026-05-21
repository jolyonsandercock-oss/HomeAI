#!/usr/bin/env python3
"""
u141-validate-presidio.py — run every corpus file through Presidio /redact
and assert each file's # EXPECT: line is met.

    PRESIDIO_URL=http://homeai-presidio:8765 \\
    PRESIDIO_CORPUS=/path/to/corpus \\
    python u141-validate-presidio.py

Exits 0 if every file passes, 1 with a per-file diff if any shortfall.
"""
import os
import re
import sys
import asyncio
import pathlib

import httpx

CORPUS_DIR   = pathlib.Path(os.environ.get("PRESIDIO_CORPUS",
                  "/home_ai/scripts/u141-presidio-test-corpus/corpus"))
PRESIDIO_URL = os.environ.get("PRESIDIO_URL", "http://homeai-presidio:8765")
EXPECT_RE = re.compile(r"^# EXPECT:\s*(.+)$", re.MULTILINE)


def parse_expect(content: str) -> dict[str, int]:
    m = EXPECT_RE.search(content)
    if not m:
        return {}
    out = {}
    for chunk in m.group(1).split(","):
        chunk = chunk.strip()
        if ":" in chunk:
            ent, n = chunk.split(":", 1)
            out[ent.strip()] = int(n)
    return out


async def amain():
    corpus = sorted(CORPUS_DIR.glob("*.txt"))
    if not corpus:
        print(f"FAIL: no corpus files under {CORPUS_DIR}", file=sys.stderr)
        return 1

    print(f"validating {len(corpus)} files against {PRESIDIO_URL}/redact")

    passes = 0
    failures: list[tuple[str, dict, dict]] = []

    async with httpx.AsyncClient(timeout=60.0) as c:
        try:
            r = await c.get(f"{PRESIDIO_URL}/healthcheck")
            r.raise_for_status()
        except Exception as e:
            print(f"FAIL: presidio /healthcheck unreachable: {e}", file=sys.stderr)
            return 1

        for f in corpus:
            text = f.read_text()
            expect = parse_expect(text)
            try:
                r = await c.post(f"{PRESIDIO_URL}/redact", json={
                    "text": text,
                    "workflow_id": f"corpus-validate:{f.name}",
                    "capability_tag": "CAP_VALIDATION",
                    "realm": "work",
                })
                r.raise_for_status()
                data = r.json()
            except Exception as e:
                print(f"FAIL[{f.name}]: redact request errored: {e}")
                failures.append((f.name, expect, {"error": str(e)}))
                continue

            hits = data["recognisers_hit"]
            shortfalls = {ent: {"want": want, "got": hits.get(ent, 0)}
                          for ent, want in expect.items()
                          if hits.get(ent, 0) < want}
            if not shortfalls:
                passes += 1
                extras = [k for k in hits if k not in expect]
                print(f"PASS[{f.name}]: {sum(expect.values())} expected (extras: {extras})")
            else:
                failures.append((f.name, expect, hits))
                print(f"FAIL[{f.name}]: shortfalls={shortfalls}, full_hits={hits}")

    print(f"\nTotal: {passes}/{len(corpus)} passing")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(amain()))
