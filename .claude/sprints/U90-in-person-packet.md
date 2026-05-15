# U90 — In-person packet: prepare Jo's next physical session

**Prereqs**: U86 + U87 + U88 + U89 audits + doc outputs available in `/home_ai/audits/` and `/home_ai/docs/`.

**Realm**: `owner` — the packet itself is for Jo. Touches all realms read-only.

**Remote-doable**: 100% for *generating* the packet. The packet itself describes work that's 100% in-person.

**Why this sprint exists**: every prior sprint queued items that need sudo, physical access, or external action (NatWest login, Xero support reply). Without a consolidated checklist these scatter and either don't get done or get done out-of-order. This sprint produces ONE document Jo executes at the box.

**Overnight-autonomous**: yes — pure file generation from prior sprints' audit outputs.

## Tracks

### T1 — Consolidate sudo-required items (~20 min)

**Build**:
- Pull from U86–U89 + STATUS.md `Pending — Jo's input` section. Identify items that need sudo at the box.
- Known starters:
  - `sudo bash /home_ai/scripts/u35-vault-autounseal-bootstrap.sh` (long-outstanding)
  - `sudo bash /home_ai/scripts/u73-install-ocr.sh` (restored in U88 T4)
  - Image updates: Vault 1.15.6 → latest, alertmanager v0.27.0 → latest, postgres-exporter v0.15.0 → latest. Per-image rollback path included.
  - Authelia full forward_auth: requires `tailscale cert <FQDN>` first, then Caddy config update.
- For each: command, expected output, time estimate, rollback.

**Acceptance**:
- Section "Sudo & in-person" lists every item with one-line command + verification step.

---

### T2 — Consolidate external-action items (~15 min)

**Build**:
- NatWest CSV pull for accounts identified in U86 T1 as under-imported (#15 zero rows, #3 sparse). Per-account: login URL, statement window (last 6 months minimum), import command (`u59-credit-card-csv-import.sh` pattern or equivalent for current accounts).
- Loan 284512-03 follow-up (U76 follow-on): what to ask Principality (current balance / payment history / which property secures it).
- Xero support chase (P3, parked).
- Companies House numbers for entities 1+2 (if not already done in some unseen sprint).
- Land Registry: 7 property postcodes (if not already done).

**Acceptance**:
- Section "External actions" lists every item with target system + expected return artefact.

---

### T3 — Generate the packet (~30 min)

**Build**:
- Script `scripts/u83-gen-packet.sh`. Emits `audits/2026-05-16-jo-checklist.md` with sections:
  1. **Pre-session** — what to have open / what creds to have to hand.
  2. **Sudo block** (T1 items) — ordered by dependency (Vault auto-unseal first because everything else needs Vault not re-sealing mid-session).
  3. **External block** (T2 items) — ordered by what the rest of the system depends on (bank import unblocks 4 reconciliation arcs).
  4. **Verification** — a single `bash /home_ai/scripts/u83-verify.sh` that confirms each block landed.
  5. **Total time estimate** — sum of per-item times.

**Acceptance**:
- Packet exists. Total time estimate at top. Verification script (T4) referenced.

---

### T4 — Post-session verification script (~30 min)

**Build**:
- `scripts/u83-verify.sh`: for each item in the packet, a check:
  - Vault: `vault status` → sealed=false, auto-unseal config present.
  - Images: `docker inspect <image> | grep -i created` → recent.
  - OCR watcher: `systemctl is-active scan-ocr-watcher` → active.
  - Bank data: `SELECT count(*) FROM bank_transactions WHERE bank_account_id=15` → > 0.
  - Authelia: `curl <FQDN>/auth/health` → 200.
- Each check prints PASS/FAIL with explanation. Exit code = count of failures.

**Acceptance**:
- Pre-session (now): all checks return FAIL appropriately (nothing changed yet).
- Post-session (Jo runs after the work): all checks return PASS.

---

### T5 — Update STATUS.md "Pending — Jo's input" (~10 min)

**Build**:
- Replace the current bullet list with a single line: "See `audits/2026-05-16-jo-checklist.md` — total time ~X hrs."
- Add a follow-on: after Jo completes the packet, `/retro` regen STATUS.md will move resolved items to "Recently completed".

**Acceptance**:
- STATUS.md no longer scatters Jo-input items; one entry point.

---

### T6 — Commit (~5 min)

**Build**:
- Single commit `U90: in-person packet (sudo + external action checklist + verify script)`.
- Update `audits/INDEX.md`.

**Acceptance**:
- Working tree clean. Packet is the deliverable; everything else points to it.

## What this sprint does NOT do

- Does **not** execute any sudo or external action — those are the packet's job, run by Jo at the box.
- Does **not** open new follow-ups; only consolidates existing ones from U86–U89.
- Does **not** ship application changes — pure orchestration.

## Follow-on sprints

- **Post-packet**: Jo runs `audits/2026-05-16-jo-checklist.md`. On completion, fires `/retro` to regenerate STATUS.md (now automated per U89 T5).
- Next functional sprint (the original U86 Clover-bank reconciliation) becomes unblocked by T2's NatWest CSV import.
