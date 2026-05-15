# STATUS

_generated: 2026-05-15T20:38:52+01:00_
_by: scripts/u89-regen-status.sh_

## Current branch

`u73-hd-samba-paperless` at `1b7f8e7`

## Recent commits (last 20)

```
1b7f8e7 U88: fix-and-forget — 4 tracks done (T1 retire + T2 disable + T6 cron + T7 TODOs)
0e63b3f U87: secure — RLS coverage + Vault rotation calendar + entropy hook + sprint-number guard
731bdf2 U86: data-integrity audit (bank coverage / FK orphans / idempotency / schema drift / dead-letters / hunters)
fe94f66 U79-U83 plans: secure-and-fix overnight arc (no new functionality)
b1c2beb U80: auto-parse mortgage statements in ingest-from-paperless webhook
03a6d01 U79: mortgage statement coverage view + Stmt coverage tab
3bb3598 U78: forensic rebuild of mortgage_accounts from OCR data
c70f905 U78: Clover batch ingest + account_property_map + scan auto-routing
999c4bc U77: capital position + net worth on /finance
476decb fix(u33-data-lane-router): mark row 'rejected' on gmail HTTP 4xx
d79440e U75: tightening pass — invoice triage UI, smoke test, hunter unique idx
bc5b8d2 U74: mortgages on /finance + property seed from chat
af6ac8c fix: _link_to_entity properties query → postcode (not postcode_full)
ac00424 U73b: Brother ADS-2800W compat — SMB1/NTLMv1 + bind to lo+LAN only
d51c4fa U73: 6TB HD ext4 + Samba scans share → Paperless consume
382bd1c U72: OI agents + missing-data hunters + ATR Trading onboarding
4bd8ff6 U71: phase-9 finish — till form, critical NOTIFY, recipes, pipeline-role runway
e50101d U70: paper-invoice OCR backbone (Paperless webhook + adapter pattern)
027c30e U69: Phase 9 — cash variance + morning digest + /recon dashboard
3fd7304 U68: RECON-L2-light + L3-daily-aggregate + nightly orchestrator
```

## Open work signals

- Pending bot_instructions: 0
- Open CRITICAL exceptions: 0
- Working-tree state: 27 files modified/untracked

## Audit log recent entries

## 2026-05-15 — U86 data-integrity sweep
## 2026-05-15 — U87 secure (RLS + Vault + entropy)
## 2026-05-15 — U88 fix-and-forget

## Active sprint plans

- `U86-audit-data-integrity.md` — U86 — Audit: data integrity sweep
- `U87-secure-rls-and-hygiene.md` — U87 — Secure: RLS coverage + Vault hygiene + entropy guard
- `U88-fix-and-forget.md` — U88 — Fix and forget: clear the known-broken pile
- `U89-tidy-doc-discipline.md` — U89 — Tidy: auto-doc, untracked sweep, process discipline
- `U90-in-person-packet.md` — U90 — In-person packet: prepare Jo's next physical session
- `U90-in-person-packet.md` — U90 — In-person packet: prepare Jo's next physical session

_Re-run: `scripts/u89-regen-status.sh`_
