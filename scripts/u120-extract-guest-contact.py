"""u120-extract-guest-contact.py — Haiku-extract guest_phone + guest_email
from accommodation_bookings.raw_text. Targets rows where contact_extracted_at
is NULL (or older than 30 days when raw_text changed).

Cache markers on system + tool so the prompt is reused across the batch.
Logs usage to ai_usage (service='u120-guest-contact').
"""
import os, json, sys, asyncio, time, urllib.request, urllib.error
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
MODEL       = "claude-haiku-4-5-20251001"
BATCH       = int(os.environ.get("BATCH", "30"))


def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": VAULT_TOKEN}), timeout=5)
    return json.loads(r.read())["data"]["data"]


SYSTEM = (
    "You are extracting guest contact details from a UK pub/hotel booking "
    "confirmation. Return phone in E.164 format (+447xxx for UK mobiles, "
    "+44x for landlines). Return email lowercased. Both fields can be null "
    "if not present. Never fabricate — only return values literally present "
    "in the text."
)

TOOL = {
    "name": "record_contact",
    "description": "Capture the guest's phone and email.",
    "input_schema": {
        "type": "object",
        "properties": {
            "phone_e164": {"type": "string", "description": "Phone in E.164 (+447...) or empty if absent"},
            "email":      {"type": "string", "description": "Email lowercased or empty if absent"},
            "confidence": {"type": "number", "description": "0.0-1.0 confidence in both fields"},
        },
        "required": ["phone_e164", "email", "confidence"],
    },
}


async def log_usage(conn, usage, booking_id):
    if not usage:
        return
    try:
        await conn.execute("""
            INSERT INTO ai_usage
              (trace_id, task_type, model_used, tier,
               prompt_tokens, completion_tokens,
               cache_creation_tokens, cache_read_tokens,
               service, realm, provider, cached)
            VALUES (NULL, 'guest.contact_extract', $1, 'cloud',
                    $2, $3, $4, $5, 'u120-guest-contact', 'work', 'anthropic', $6)
        """, MODEL,
             usage.get("input_tokens", 0) or 0,
             usage.get("output_tokens", 0) or 0,
             usage.get("cache_creation_input_tokens", 0) or 0,
             usage.get("cache_read_input_tokens", 0) or 0,
             bool(usage.get("cache_read_input_tokens")))
    except Exception as e:
        print(f"[usage-log] {e}")


async def extract_one(client_post, anth_key, raw_text):
    payload = {
        "model": MODEL,
        "max_tokens": 200,
        "system": [{"type": "text", "text": SYSTEM,
                    "cache_control": {"type": "ephemeral"}}],
        "tools": [{**TOOL, "cache_control": {"type": "ephemeral"}}],
        "tool_choice": {"type": "tool", "name": "record_contact"},
        "messages": [{"role": "user", "content": raw_text[:6000]}],
    }
    r = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode(),
        headers={"x-api-key": anth_key,
                 "anthropic-version": "2023-06-01",
                 "content-type": "application/json"}, method="POST")
    j = None  # U245: retry/cooldown on 529/overloaded + transient network
    for _att in range(6):
        try:
            j = json.loads(urllib.request.urlopen(r, timeout=60).read()); break
        except urllib.error.HTTPError as e:
            if e.code in (408, 409, 429, 500, 502, 503, 529) and _att < 5:
                time.sleep(min(60, 2 * (2 ** _att))); continue
            raise
        except (urllib.error.URLError, TimeoutError):
            if _att < 5:
                time.sleep(min(60, 2 * (2 ** _att))); continue
            raise
    for b in j.get("content") or []:
        if b.get("type") == "tool_use":
            return b["input"], j.get("usage")
    return None, j.get("usage")


async def main():
    pw = vault("postgres")["password"]
    anth = vault("anthropic")["api_key"]
    conn = await asyncpg.connect(f"postgresql://postgres:{pw}@homeai-postgres:5432/homeai")
    await conn.execute("SELECT home_ai.set_realm('owner')")

    targets = await conn.fetch("""
        SELECT id, guest_name, raw_text
          FROM accommodation_bookings
         WHERE status IN ('confirmed','deposit_paid','paid','active')
           AND checkin_date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE + 30
           AND contact_extracted_at IS NULL
           AND raw_text IS NOT NULL
           AND length(raw_text) > 100
         ORDER BY checkin_date
         LIMIT $1
    """, BATCH)
    print(f"to extract: {len(targets)}")

    captured = 0
    for r in targets:
        try:
            extracted, usage = await extract_one(None, anth, r["raw_text"])
            await log_usage(conn, usage, r["id"])
            if extracted:
                phone = (extracted.get("phone_e164") or "").strip() or None
                email = (extracted.get("email") or "").strip() or None
                conf  = float(extracted.get("confidence") or 0)
                # Sanity-gate: only accept if confidence ≥ 0.7
                if conf >= 0.7:
                    await conn.execute("""
                        UPDATE accommodation_bookings
                           SET guest_phone = COALESCE($2, guest_phone),
                               guest_email = COALESCE($3, guest_email),
                               contact_extracted_at = NOW(),
                               contact_extract_model = $4
                         WHERE id = $1
                    """, r["id"], phone, email, MODEL)
                    if phone or email:
                        captured += 1
                        print(f"  #{r['id']} {r['guest_name']}: phone={phone} email={email} conf={conf:.2f}")
                else:
                    print(f"  #{r['id']} {r['guest_name']}: low confidence {conf:.2f}, skipping")
                    await conn.execute(
                        "UPDATE accommodation_bookings SET contact_extracted_at=NOW(), contact_extract_model=$2 WHERE id=$1",
                        r["id"], f"{MODEL}-lowconf")
        except Exception as e:
            print(f"  #{r['id']} error: {e}")

    print(f"captured contact for {captured}/{len(targets)}")
    await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
