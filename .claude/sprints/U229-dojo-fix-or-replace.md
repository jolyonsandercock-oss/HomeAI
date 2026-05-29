# U229 — Dojo: fix or replace

**Realm:** work (pub Dojo settlement). Per memory `feedback-cafe-vendor-truth` Dojo at the pub is the live revenue stream that drives ATR Trading current account.

**Trigger:** `u135-dojo-inbox-sweep.sh` invokes `docker exec homeai-postgres python3 …` — but `homeai-postgres` doesn't have python3 installed, and `/home_ai/scripts/` isn't mounted into it. Discovered 2026-05-28 during manual run of the script: every cron tick at 05:30 has been failing silently. Result: `dojo_transactions` is 8d stale (latest 2026-05-21) even though Jo's been dropping CSVs into `/home_ai/data/dojo-inbox/`.

**Status:** queued.

**Why it matters:** Dojo is the daily pub revenue truth. The "Work cash position" tile on Mission Control depends on it; the bot's daily revenue update misses Dojo when the table is stale; reconciliation of the ATR Trading current account depends on matched Dojo settlements. 8d gap = 8 dashboard tiles wrong.

---

## T1 — Pick the path

Two options, pick one in T1:

| | A) Cheap fix | B) Playwright replace |
|---|---|---|
| Effort | ~30 min | ~3–4 hrs |
| Removes manual CSV drop? | No | Yes |
| Risk | Low | Medium (Dojo dashboard auth, layout drift) |
| Memory ref | `feedback-pdfplumber-service` (similar exec-into-different-container pattern) | `feedback-trail-oidc-not-api` (same Playwright pattern as U230) |

**Recommended:** B if combining with U230 (shared Playwright work); A if shipping standalone.

Decision goes in `/home_ai/.claude/decisions/U229-dojo-path.md`.

## T2a — Cheap fix path (if A chosen)

The script needs to run the python parser somewhere that has python3 + access to the CSV + a route to postgres.

- [ ] Move the python exec from `homeai-postgres` to `homeai-bot-responder` (has python3, on ai-internal network, can reach postgres).
- [ ] Confirm `/home_ai/scripts/dojo-import.py` works when invoked from bot-responder; mount the scripts dir into bot-responder if not already (`/home_ai/scripts:/home_ai/scripts:ro` bind mount via compose).
- [ ] Update `u135-dojo-inbox-sweep.sh` lines 18–20:
  - keep `docker exec -i homeai-postgres bash -c "cat > /tmp/dojo-…"` (postgres still needs the file for `\copy` if the parser uses that) OR
  - change to `cat "$csv" | docker exec -i homeai-bot-responder python3 /home_ai/scripts/dojo-import.py -` and feed via stdin
- [ ] Test manually with one CSV.
- [ ] Verify next 05:30 cron run picks up any waiting CSVs.

## T2b — Playwright replace path (if B chosen)

Eliminate the CSV drop entirely. Dojo's merchant dashboard exposes transaction history; an authenticated Playwright session pulls daily.

- [ ] Confirm Dojo dashboard auth path (likely email/password + possibly 2FA — needs Jo on-site for first run to pair).
- [ ] Store creds in vault at `secret/dojo` (matches `secret/trail` pattern).
- [ ] New container `homeai-dojo-poll` OR reuse `homeai-playwright` with a new `/ingest/dojo` endpoint.
- [ ] Daily cron at 05:30 hits the endpoint → returns parsed JSON → upserts to `dojo_transactions` via existing `idempotency_key`.
- [ ] Decommission `u135-dojo-inbox-sweep.sh` + `/home_ai/data/dojo-inbox/` once Playwright path is proven.

## T3 — Backfill the inbox

Whichever path is chosen, there are CSVs sitting in `/home_ai/data/dojo-inbox/` from the failed cron runs. Process them once before the new path takes over.

- [ ] Inventory: `ls -la /home_ai/data/dojo-inbox/`
- [ ] Run the fixed sweep manually with `--once` (or equivalent) against each unprocessed CSV.
- [ ] Verify `dojo_transactions.MAX(transaction_date)` advances to within last 48h.

## T4 — Verify + close

- [ ] `v_dojo_freshness.hours_stale < 30` (under daily-window threshold).
- [ ] Mission Control work-cash tile updates from Dojo end-of-day.
- [ ] `u35-upload-tasks-email` no longer surfaces dojo as a stale source.
- [ ] Update memory `project-vault-recovered-2026-05-28` to remove the "Dojo CSV import script broken" caveat once shipped.

---

## Deferred / out of scope

- **Dojo Open API integration** — Dojo has a developer API but the merchant tier doesn't currently include it; revisit if the tier changes.
- **Real-time webhook from Dojo** — would replace daily-batch entirely; out of scope until / unless Dojo offers it on this merchant tier.
- **Per-transaction matching to bank reconciliation** — separate sprint (rolled into U227 backfills first).
