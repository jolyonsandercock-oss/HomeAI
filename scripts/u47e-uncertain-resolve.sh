#!/bin/bash
# /home_ai/scripts/u47e-uncertain-resolve.sh
#
# Take every row in v_classifier_uncertain (qwen2.5:7b confidence 0.80–0.85)
# and re-classify with Claude Haiku. Three outcomes per row:
#
#   AGREE+confident   — Haiku gives same category at >=0.92.
#                        Insert bot_feedback with corrected_class=original_class
#                        (a confirmation, not a correction) so already_reviewed=true
#                        and the row drops out of the uncertain view.
#
#   DISAGREE          — Haiku proposes a different category at >=0.85.
#                        Insert bot_feedback proposing the correction. The existing
#                        overnight feedback-application pipeline will surface it
#                        to Jo via the invoices page Feedback modal.
#
#   STILL-UNCERTAIN   — Haiku also under 0.85. Leave alone; bumped to Telegram
#                        summary for manual review.
#
# Usage:
#   ./scripts/u47e-uncertain-resolve.sh            # default: 30 most uncertain
#   ./scripts/u47e-uncertain-resolve.sh 200        # process up to N

set -uo pipefail
LIMIT="${1:-30}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e LIMIT="$LIMIT" -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, time, urllib.request, urllib.parse, urllib.error
import asyncpg

LIMIT = int(os.environ["LIMIT"])
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]

CATS = ['invoice','action-required','report-attachment',
        'school-medical','property','pub','fyi','junk']

SYSTEM = (
  "You are the Home AI email classifier. Classify into EXACTLY one of: "
  "invoice, action-required, report-attachment, school-medical, property, pub, fyi, junk.\n\n"
  "  invoice           — supplier BILL requesting payment with total due\n"
  "  action-required   — payment declined, login alert, deadline\n"
  "  report-attachment — daily/weekly business report (EPOS, occupancy)\n"
  "  school-medical    — school, GP, hospital, child health/education\n"
  "  property          — tenant, repair, viewing, Estates property\n"
  "  pub               — operational pub matter not invoice/report\n"
  "  fyi               — receipts, marketing, newsletters\n"
  "  junk              — spam, phishing, unsolicited\n\n"
  "Receipts/refunds/payment confirmations are NOT invoices — they are fyi.\n"
  "Payment failures/declines are NOT invoices — they are action-required.\n\n"
  'Return ONLY this JSON: {"category": "<one of the 8>", "confidence": 0.0-1.0, "reason": "<8 words max>"}'
)


def vault_get(path, key):
    req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"][key]


def haiku(api_key, user_msg):
    body = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 200,
        "system": SYSTEM,
        "messages": [{"role": "user", "content": user_msg}],
    }
    req = urllib.request.Request("https://api.anthropic.com/v1/messages",
        data=json.dumps(body).encode(),
        headers={"x-api-key": api_key, "anthropic-version": "2023-06-01",
                 "Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=30)
    out = json.loads(r.read())
    text = out["content"][0]["text"].strip()
    # strip markdown fences if Haiku wrapped it
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text
        if text.endswith("```"):
            text = text.rsplit("```", 1)[0]
    text = text.strip()
    # find first {...} block
    start = text.find("{"); end = text.rfind("}")
    if start >= 0 and end > start:
        text = text[start:end+1]
    return json.loads(text)


async def main():
    api_key = vault_get("anthropic", "api_key")
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")
    # R6: classifier uncertain queue spans cross-realm emails — OWNER scope.
    await conn.execute("SET app.current_realm = 'owner'")

    rows = await conn.fetch(f"""
      SELECT u.email_id, u.gmail_message_id, u.classification AS orig_class,
             u.confidence_score AS orig_conf,
             e.from_address, e.subject, e.body_text_safe, e.body_text
        FROM v_classifier_uncertain u
        JOIN emails e ON e.id = u.email_id
       WHERE u.already_reviewed=false
       ORDER BY u.confidence_score ASC, u.received_at DESC
       LIMIT {LIMIT}
    """)
    print(f"Found {len(rows)} uncertain rows to resolve.")

    confirmed = corrected = still_uncertain = errored = 0
    disagreements = []

    for r in rows:
        body = (r["body_text_safe"] or r["body_text"] or "")[:3500]
        user_msg = f"From: {r['from_address']}\nSubject: {r['subject']}\n\n{body}"
        try:
            res = haiku(api_key, user_msg)
            cat  = res.get("category")
            conf = float(res.get("confidence") or 0)
            reason = (res.get("reason") or "")[:80]
        except urllib.error.HTTPError as e:
            print(f"  [{r['email_id']:>6}] Haiku HTTP {e.code}: {e.read().decode()[:120]}")
            errored += 1; continue
        except Exception as e:
            print(f"  [{r['email_id']:>6}] Haiku error: {e}")
            errored += 1; continue

        if cat not in CATS:
            print(f"  [{r['email_id']:>6}] invalid category '{cat}' → skip")
            errored += 1; continue

        agrees = (cat == r["orig_class"])
        outcome = None
        if conf < 0.85:
            outcome = "still-uncertain"
            still_uncertain += 1
        elif agrees and conf >= 0.92:
            outcome = "confirm"
            confirmed += 1
            await conn.execute("""
              INSERT INTO bot_feedback
                (email_id, domain, original_class, corrected_class, original_conf, notes)
              VALUES ($1, 'classifier', $2, $2, $3,
                      $4)
            """, r["email_id"], r["orig_class"], r["orig_conf"],
                 f"u47e-haiku-confirm conf={conf:.2f} reason={reason}")
        elif not agrees and conf >= 0.85:
            outcome = "correct"
            corrected += 1
            disagreements.append((r["email_id"], r["orig_class"], cat, conf,
                                  (r["subject"] or "")[:50], reason))
            await conn.execute("""
              INSERT INTO bot_feedback
                (email_id, domain, original_class, corrected_class, original_conf, notes)
              VALUES ($1, 'classifier', $2, $3, $4, $5)
            """, r["email_id"], r["orig_class"], cat, r["orig_conf"],
                 f"u47e-haiku-correct conf={conf:.2f} reason={reason}")
        else:
            outcome = "agree-low-conf"
            still_uncertain += 1

        print(f"  [{r['email_id']:>6}] {r['orig_class']:>16} → {cat:<16} conf={conf:.2f} {outcome:<14} | {(r['subject'] or '')[:40]}")
        time.sleep(0.15)  # polite pacing

    await conn.close()

    print()
    print(f"── summary ──")
    print(f"  confirmed       : {confirmed}")
    print(f"  corrected       : {corrected}")
    print(f"  still uncertain : {still_uncertain}")
    print(f"  errored         : {errored}")
    if disagreements:
        print("\nDisagreements (top 10):")
        for did, oc, nc, cf, sub, rsn in disagreements[:10]:
            print(f"  #{did}  {oc} → {nc}  conf={cf:.2f}  '{sub}'  ({rsn})")

    # Telegram nudge if there are still uncertain ones
    if still_uncertain > 0 or disagreements:
        try:
            tok = vault_get("telegram", "bot_token")
            chat = vault_get("telegram", "chat_id")
            msg = (f"U47e uncertainty resolve:\n"
                   f"• Haiku confirmed {confirmed}\n"
                   f"• Haiku corrected {corrected} (proposed via bot_feedback)\n"
                   f"• Still uncertain {still_uncertain}\n"
                   f"Open: http://100.104.82.53/dashboard/invoices")
            urllib.request.urlopen(urllib.request.Request(
                f"https://api.telegram.org/bot{tok}/sendMessage",
                data=urllib.parse.urlencode({"chat_id": chat, "text": msg}).encode()),
                timeout=15)
        except Exception as e:
            print(f"(telegram nudge failed: {e})")


asyncio.run(main())
PYEOF
