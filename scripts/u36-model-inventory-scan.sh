#!/bin/bash
# /home_ai/scripts/u36-model-inventory-scan.sh
#
# Workflow A: weekly snapshot of Ollama /api/tags. Diff against last week's
# snapshot. Telegram-alert on additions/removals/size-changes.
#
# Cron: 0 3 * * 0  (Sundays 03:00)
# Idempotent — re-runs simply append a new snapshot row.

set -uo pipefail

docker exec -i homeai-playwright python <<'PYEOF'
import os, json, urllib.request, asyncio, asyncpg
from datetime import datetime, timezone

PG_DSN = os.environ["PG_DSN"]


def fetch_tags():
    r = urllib.request.urlopen("http://ollama:11434/api/tags", timeout=15)
    return json.load(r).get("models", [])


async def main():
    models = fetch_tags()
    print(f"current models: {len(models)}")
    if not models:
        print("(no models — Ollama empty or unreachable)")
        return

    conn = await asyncpg.connect(PG_DSN)
    # last snapshot's set of model names (most recent snapshot_at across all rows)
    prev = await conn.fetch("""
      SELECT model_name, size_bytes, parameter_size
        FROM model_inventory_log
       WHERE snapshot_at = (SELECT MAX(snapshot_at) FROM model_inventory_log)
    """)
    prev_by_name = {p["model_name"]: dict(p) for p in prev}

    # Insert this snapshot
    cur_set = set()
    for m in models:
        details = m.get("details") or {}
        await conn.execute("""
          INSERT INTO model_inventory_log
            (model_name, size_bytes, parameter_size, quantization, modified_at, raw_payload)
          VALUES ($1, $2, $3, $4, $5, $6)
        """,
          m.get("name"),
          m.get("size"),
          details.get("parameter_size"),
          details.get("quantization_level"),
          datetime.fromisoformat(m["modified_at"].replace("Z","+00:00")) if m.get("modified_at") else None,
          json.dumps(m))
        cur_set.add(m.get("name"))
    print(f"snapshot inserted: {len(models)} rows")

    prev_set = set(prev_by_name.keys())
    added   = cur_set - prev_set
    removed = prev_set - cur_set
    # Size changes for models in both snapshots
    sized_changed = []
    for m in models:
        n = m.get("name")
        if n in prev_by_name and prev_by_name[n]["size_bytes"] and prev_by_name[n]["size_bytes"] != m.get("size"):
            sized_changed.append((n, prev_by_name[n]["size_bytes"], m.get("size")))

    # Build summary
    if not prev_set:
        msg = f"🦙 First model inventory snapshot: {len(models)} models tracked.\n"
        for m in models:
            details = m.get("details") or {}
            msg += f"  • {m['name']} ({details.get('parameter_size','?')} {details.get('quantization_level','?')})\n"
    elif added or removed or sized_changed:
        msg = "🦙 Ollama inventory change:\n"
        for a in added:     msg += f"  + added:    {a}\n"
        for r in removed:   msg += f"  - removed:  {r}\n"
        for n, old, new in sized_changed:
            delta = (new - old) / 1024 / 1024
            msg += f"  ~ resized:  {n} ({delta:+.0f} MB → {new/1024/1024/1024:.2f} GB total)\n"
    else:
        msg = None

    if msg:
        print("--- alert ---")
        print(msg)
        # Send Telegram via notify-telegram.sh from host (post-exit hook).
        # We can't shell out to host from inside playwright — write to a marker
        # file the calling script will read and forward.
        with open("/tmp/u36-model-inventory-msg.txt", "w") as f:
            f.write(msg)

    await conn.close()

asyncio.run(main())
PYEOF

# If the python wrote a message file, ferry it through notify-telegram on the host
MSG_FILE=$(docker exec homeai-playwright sh -c 'test -f /tmp/u36-model-inventory-msg.txt && cat /tmp/u36-model-inventory-msg.txt; rm -f /tmp/u36-model-inventory-msg.txt' 2>/dev/null)
if [[ -n "$MSG_FILE" ]]; then
  bash /home_ai/.claude/scripts/notify-telegram.sh "$MSG_FILE" "model-inventory" >/dev/null 2>&1 || true
fi
