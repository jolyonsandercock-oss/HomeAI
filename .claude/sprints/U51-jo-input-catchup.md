# U51 — Jo-Input Catch-Up

**Prereqs**: none.

**Remote vs in-person**: ~70/30. The Authelia + NAS + SDD bits below need physical-or-sudo access; everything else is remote-with-Jo-Q&A.

**Why this sprint exists**: every other open debt item now sits behind something only Jo can do — reply to a Telegram prompt, paste an API key, run an installer with sudo, or dictate facts that aren't in any system (vehicle reg + MOT dates, decisions about NAS). The build side cannot move further on its own. This sprint front-loads the "stuff only Jo can do," batches it into one sitting so Jo isn't context-switched repeatedly, and queues the unblocked downstream work into U52 with no further Jo input needed.

**Design rule**: every track lists *exactly* what Jo types or runs. No "decide later" — every track ends in a written value or a decision recorded in `bot_instructions`.

## Tracks

### T1 — Reply to cafe-vendor Telegram prompt (~1 min, in chat)

Telegram msg 9259 (sent 2026-05-14 09:43) is still unanswered. The `u47d-cafe-vendor-apply.sh` cron runs every 10 min waiting for a `cafe: <n,n,...>` reply.

**Jo does**: open Telegram, scroll to msg 9259, reply `cafe: <list of cafe-only ids>`. For the current top-25 list, candidate cafe vendors look like: `4 booking.com`, `21 bidfreshfinance.co.uk`, `22 dojo.tech`, `24 encounterwalkingholidays.com`. Jo's local knowledge is the ground truth — list whatever subset belongs to the Sandwich Bar / Ice Cream Shop.

**Acceptance**: `SELECT applied_at FROM cafe_vendor_prompt_state WHERE id=1` is non-null within 10 minutes; `vendor_category_rules WHERE site='cafe'` row count > 0.

---

### T2 — Install hooks in ~/.claude/settings.json (~2 min, terminal)

The `no-secrets-in-files.sh` + `sql-rules.sh` PreToolUse hooks exist and tested. The agent cannot self-modify `~/.claude/settings.json`.

**Jo runs**:
```bash
bash /home_ai/.claude/scripts/u13-install-hooks.sh
```
The installer backs up settings.json, jq-merges the hook entries, runs negative tests, prints PASS/FAIL.

**Acceptance**: `jq '.hooks.PreToolUse' ~/.claude/settings.json` returns a non-empty array.

---

### T3 — Xero OAuth retry (~15 min, browser + terminal)

Status from U29: fresh app rejected at `/connect/authorize`, even minimal scope, even in incognito. Email sent to api@xero.com, no reply yet.

**Pre-flight (Jo, 5 min)**:
1. Open https://developer.xero.com/app/manage — is the original app still there?
2. Click into it → check the redirect URI exactly matches `http://localhost:8765/callback`
3. Check the "Company or application name" → must be **Atlantic Road Trading Ltd**, not Estates
4. Note client_id and client_secret values (or generate a fresh secret)
5. If api@xero.com replied, paste the gist of their reply into Telegram

**Then Jo runs**:
```bash
python3 /home_ai/scripts/u29-xero-bootstrap.py
```
It prompts for client_id + client_secret, opens the auth URL, captures the code, exchanges for tokens, stashes to `secret/xero` in Vault.

**Acceptance**: `vault kv get secret/xero` returns `access_token` + `refresh_token` + `tenant_id` + `expires_at`.

**If still rejected**: capture the new errorId, paste into Telegram. We park this for the third time and document the blocker as permanent until Xero responds.

---

### T4 — NAS decision revisit (~5 min, decision)

Postponed 2026-05-11. `restic` snapshots still local-only.

**Jo decides one of**:

(a) **Mount the NAS now**: `sudo bash /home_ai/.claude/scripts/u13-mount-nas.sh` (interactive SMB/NFS, idempotent). 5 min if NAS is on the network.

(b) **Keep postponed**: Jo replies in Telegram `nas: postponed until <date>` — recorded in `bot_instructions` so we stop re-flagging it.

(c) **Use cloud backup instead**: Jo provides B2 / S3 / Wasabi creds via a new bootstrap (build-side ~30 min to write).

**Acceptance**: `bot_instructions` has a row with `intent='nas-decision'` and a resolution.

---

### T5 — Vehicle / MOT intake (~20 min, terminal Q&A)

Build side (~60 min, autonomous before Jo sits down):
- V62 migration: `vehicles` table (`id`, `registration`, `make_model`, `year`, `v5c_doc_ref`, `mot_due`, `insurance_renewal`, `road_tax_due`, `service_due_miles`, `entity_id`, `notes`, `created_at`)
- V62 migration: `v_vehicle_alerts` view that surfaces vehicles with any due-date inside 30 days
- `scripts/u51-vehicle-intake.sh` — guided prompt: per-vehicle, asks for each field with validation (regex for UK reg `^[A-Z0-9 ]{1,8}$`, date sanity etc.); INSERTs into the table; can be re-run idempotently keyed on registration.
- `scripts/u51-vehicle-alerts.sh` — daily 09:00 cron checking the view, Telegram-pings when any due-date enters 14-day window
- `/api/vehicles` + `static/vehicles.html` Tabulator page on the dashboard

**Jo runs once**:
```bash
bash /home_ai/scripts/u51-vehicle-intake.sh
```
Then dictates the 4 vehicles he mentioned to Gemini: registration, make/model, year, MOT due date, insurance renewal, road tax due, V5 reference.

**Acceptance**: `SELECT COUNT(*) FROM vehicles` = 4; dashboard `/dashboard/vehicles` lists all 4; cron emits Telegram for any expiring inside 14d.

---

### T6 — External API key intake (~15 min, browser sign-ups + paste)

All three are blocked on a Jo account at the provider end. Build side has no work until creds land.

(a) **Companies House Public Data API** — free.
  1. Jo visits https://developer.company-information.service.gov.uk/ → register → create application → copy API key.
  2. Jo runs `bash /home_ai/scripts/u51-companies-house-creds.sh` (to build, ~10 min). Prompts for API key, validates with a test call to `/company/00000006` (sanity), stashes to `secret/companies-house`.

(b) **Land Registry API** — £3/title via card; uses pay-as-you-go.
  1. Jo visits https://landregistry.data.gov.uk/ for the open data API (free for Price Paid + Transactions, no key needed) — actually free, no creds for the Linked Data API. Confirmable.
  2. Or HMLR Business Gateway (paid) — requires VAT-registered business account. Defer this unless free open-data API is insufficient.

(c) **HMRC VAT MTD OAuth** — large. Two paths:
  1. Sandbox client (free) — Jo registers at https://developer.service.hmrc.gov.uk/, creates a sandbox application, returns to U52 with the client_id/secret.
  2. Production — full MTD enrolment, takes weeks. Out of scope this sprint.

**Acceptance**: `vault kv get secret/companies-house` returns an API key; HMRC sandbox decision logged in `bot_instructions`.

---

### T7 — Bundle in-person items into a "next time at the box" checklist (~5 min, no input)

Build side only — produce `/home_ai/notes/2026-05-14-jo-in-person-checklist.md` listing every remaining in-person item with sequence + sudo commands + acceptance:

1. SDD migration — partition + mount + rsync data dir
2. Authelia full forward_auth + Vault rotation reconcile (30 min)
3. Caddy reverse-proxy routes for /dashboard, /metabase, /auth/ (30 min)
4. Hook install if T2 not yet done

The checklist becomes a single page Jo can work through when he's physically at the box — eliminates "what was I supposed to do again" cost.

**Acceptance**: file exists and covers the four items above with copy-pasteable commands.

---

### T8 — Sprint exit log (~5 min, autonomous)

Walk through every `needs_user` entry in `data/tasks.yaml` and `data/debt.yaml`, mark each as resolved / re-deferred-with-reason / still-blocked-externally. Anything still externally-blocked (Xero, HMRC) gets a clear "what we're waiting on" annotation so we don't keep retrying it.

## Sequencing for Jo

Jo's actual sitting (~45–65 min once T5+T6 scripts are built):

```
T1 (1m)   →   open Telegram, reply `cafe: ...`
T2 (2m)   →   bash /home_ai/.claude/scripts/u13-install-hooks.sh
T6a (5m)  →   sign up at Companies House, paste key into u51-companies-house-creds.sh
T3 (15m)  →   walk through Xero developer portal, run u29-xero-bootstrap.py
T5 (20m)  →   bash /home_ai/scripts/u51-vehicle-intake.sh, dictate 4 vehicles
T4 (5m)   →   decide NAS path, reply in Telegram
T6c (5m)  →   decide HMRC sandbox vs deferred, reply in Telegram
```

Everything else (T7, T8) is autonomous.

## Sequence (build side)

| Order | Task                                    | Effort | Notes                          |
|-------|-----------------------------------------|--------|--------------------------------|
| 1     | T5 build — V62 + intake script + cron   | 60m    | does not need Jo input         |
| 2     | T6a build — companies-house creds tool  | 10m    | does not need Jo input         |
| 3     | T7 build — in-person checklist          | 5m     | does not need Jo input         |
| 4     | wait                                    | —      | Jo runs through Tracks         |
| 5     | T8 — sprint exit log                    | 5m     | after Jo's session             |

Build-side **~75 min**, Jo's sitting **~45–65 min**, total wall clock **~2.5h** with handoffs.

## Out of scope

- ci-autofix GitHub Actions (no daily-driver impact)
- column-order-cleanup (cosmetic)
- VAT Return live wiring (depends on T6c outcome)
- Workforce cost-allocation refinements (done in U50)
- Hooks redesign — only install, not author

## What we are explicitly *not* doing

- Re-emailing Xero (let them reply or not, don't pile up tickets)
- Building anything that needs Xero before T3 succeeds — it stays parked
- Anything that requires the SDD or full Authelia — bundled into the in-person checklist for a separate session

Reply `go` to start the build side; Jo's sitting is queued for after T5+T6a scripts are ready.
