"""u119-staff-draft.py — drafters for staff WA messages.

Run inside any container with VAULT_TOKEN + asyncpg installed
(homeai-bot-responder works). Reads workforce_users + workforce_shifts
and pushes draft rows into wa_outbound_queue (status='pending_approval').

Subcommands:
    rota-published                  one nudge per staff with a shift in next 7d
    cover-request <name> <date> <start> <end> [site]
"""
import os, json, sys, re, asyncio, urllib.request
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]


def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": VAULT_TOKEN}), timeout=5)
    return json.loads(r.read())["data"]["data"]


def to_e164(raw, default_cc="44"):
    """Normalise a UK number string → E.164.
    07xxx → +447xxx ; 447xxx → +447xxx ; +447xxx pass-through."""
    if not raw:
        return None
    digits = re.sub(r"[^\d+]", "", raw)
    if digits.startswith("+"):
        return digits
    if digits.startswith("00"):
        return "+" + digits[2:]
    if digits.startswith("0"):
        return "+" + default_cc + digits[1:]
    if digits.startswith(default_cc):
        return "+" + digits
    if 10 <= len(digits) <= 15:
        return "+" + digits
    return None


async def queue_draft(conn, *, account, target_jid, target_label, body, reason, drafted_by):
    return await conn.fetchval("""
        INSERT INTO wa_outbound_queue
          (account, target_jid, target_label, body,
           drafted_by, draft_reason, status, realm)
        VALUES ($1, $2, $3, $4, $5, $6, 'pending_approval',
                CASE WHEN $1='personal' THEN 'family' ELSE 'work' END)
        RETURNING id
    """, account, target_jid, target_label, body, drafted_by, reason)


async def rota_published(conn):
    rows = await conn.fetch("""
        SELECT DISTINCT
          u.id, u.preferred_name, u.full_name,
          u.raw_payload->>'phone' AS phone
          FROM workforce_users u
          JOIN workforce_shifts s ON s.user_external_id = u.external_id
         WHERE s.shift_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 7
           AND u.raw_payload->>'phone' IS NOT NULL
         ORDER BY u.preferred_name
    """)
    queued = skipped = 0
    for r in rows:
        name = (r["preferred_name"] or r["full_name"] or "").strip()
        # Collapse any double spaces from the data
        name = re.sub(r"\s+", " ", name)
        phone = to_e164(r["phone"])
        if not phone:
            skipped += 1
            continue
        body = (f"Hi {name}, this week's rota is published in Tanda. "
                f"Reply if any clashes. Thanks — Jo")
        qid = await queue_draft(conn,
                                account="pub", target_jid=phone, target_label=name,
                                body=body, reason="rota nudge",
                                drafted_by="u119-rota-published")
        print(f"  queued #{qid} → {name} {phone}")
        queued += 1
    print(f"queued {queued}, skipped {skipped} (no phone)")


async def cover_request(conn, name, shift_date, start, end, site):
    row = await conn.fetchrow("""
        SELECT preferred_name, full_name, raw_payload->>'phone' AS phone
          FROM workforce_users
         WHERE preferred_name ILIKE $1 OR full_name ILIKE $1
         LIMIT 1
    """, f"%{name}%")
    if not row or not row["phone"]:
        print(f"no phone for '{name}'")
        return
    label = re.sub(r"\s+", " ", row["preferred_name"] or row["full_name"]).strip()
    phone = to_e164(row["phone"])
    body = (f"Hi {label}, could you cover {shift_date} {start}–{end} "
            f"at the {site}? Reply YES/NO. Thanks — Jo")
    qid = await queue_draft(conn,
                            account="pub", target_jid=phone, target_label=label,
                            body=body, reason=f"cover request {shift_date}",
                            drafted_by="u119-cover-request")
    print(f"queued #{qid} → {label} {phone}")


async def main():
    pw = vault("postgres")["password"]
    conn = await asyncpg.connect(f"postgresql://postgres:{pw}@homeai-postgres:5432/homeai")
    await conn.execute("SELECT home_ai.set_realm('owner')")
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "rota-published":
        await rota_published(conn)
    elif cmd == "cover-request":
        if len(sys.argv) < 6:
            print("Usage: cover-request <name> <date YYYY-MM-DD> <start HH:MM> <end HH:MM> [site]")
            return
        await cover_request(conn, sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
                            sys.argv[6] if len(sys.argv) > 6 else "pub")
    else:
        print(__doc__)
    await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
