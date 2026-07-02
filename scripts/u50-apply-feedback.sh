#!/bin/bash
# /home_ai/scripts/u50-apply-feedback.sh
#
# Drain bot_feedback (domain='classifier', applied=false) back to emails.
#
# Two cases:
#   corrected != original  →  UPDATE emails.classification, confidence=0.99,
#                              requires_human=false. Mark feedback applied.
#   corrected == original  →  Confirmation (Haiku or Jo agreed). Just
#                              UPDATE emails.requires_human=false,
#                              confidence=GREATEST(current, 0.92). Mark
#                              feedback applied.
#
# Cron: hourly at minute 23.

set -euo pipefail

docker exec -i homeai-playwright python << 'PYEOF'
import os, asyncio
import asyncpg

PG_DSN = os.environ["PG_DSN"]


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")
    # R6: classifier feedback applies cross-realm — OWNER scope.
    await conn.execute("SET app.current_realm = 'owner'")

    rows = await conn.fetch("""
      SELECT id, email_id, original_class, corrected_class, original_conf, notes
        FROM bot_feedback
       WHERE applied=false
         AND domain='classifier'
         AND email_id IS NOT NULL
       ORDER BY id ASC
    """)
    print(f"Found {len(rows)} unapplied classifier-feedback rows.")

    applied_correct = applied_confirm = errored = 0
    async with conn.transaction():
        for r in rows:
            try:
                if r["corrected_class"] and r["corrected_class"] != r["original_class"]:
                    res = await conn.execute("""
                      UPDATE emails
                         SET classification = $2,
                             confidence_score = 0.990,
                             requires_human = false
                       WHERE id = $1
                    """, r["email_id"], r["corrected_class"])
                    action = f"emails.classification {r['original_class']}→{r['corrected_class']}"
                    applied_correct += 1
                else:
                    res = await conn.execute("""
                      UPDATE emails
                         SET requires_human = false,
                             confidence_score = GREATEST(COALESCE(confidence_score,0), 0.920)
                       WHERE id = $1
                    """, r["email_id"])
                    action = "emails.requires_human=false (confirmation)"
                    applied_confirm += 1
                await conn.execute("""
                  UPDATE bot_feedback
                     SET applied=true, applied_at=now(), applied_action=$2
                   WHERE id=$1
                """, r["id"], action)
            except Exception as e:
                print(f"  [fb#{r['id']} email#{r['email_id']}] ERROR: {e}")
                errored += 1

    remaining = await conn.fetchval("""
      SELECT COUNT(*) FROM bot_feedback
       WHERE applied=false AND domain='classifier' AND email_id IS NOT NULL
    """)
    uncertain_now = await conn.fetchval(
        "SELECT COUNT(*) FROM v_classifier_uncertain")

    print(f"── summary ──")
    print(f"  corrections applied   : {applied_correct}")
    print(f"  confirmations applied : {applied_confirm}")
    print(f"  errors                : {errored}")
    print(f"  remaining unapplied   : {remaining}")
    print(f"  v_classifier_uncertain (current): {uncertain_now}")
    await conn.close()


asyncio.run(main())
PYEOF
