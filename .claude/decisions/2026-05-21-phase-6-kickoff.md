# ADR — Phase 6 kickoff: operational close-the-loop

**Date:** 2026-05-21
**Status:** Proposed
**Supersedes:** N/A — this is a phase boundary.
**Predecessor:** Phase 5 (Presidio + LiteLLM + quota + RLS-role-split — see U141-U145 commits).

---

## What Phase 5 delivered

Operational AI hardening for the `work` realm:

- **PII redaction** (U141): every cloud-bound call via llm-router passes through homeai-presidio first. Hard-fail on Presidio outage. Telegram bot exempt.
- **Cost gateway** (U143): ai_usage extended with business_priority / capability_tag / cost_gbp; auto-populated on INSERT. Backfilled per the £3/day budget split (P0=30% floor, P1=35%, P2=21%, P3=14%).
- **Quota allocations** (U144): per-tier daily £ ceilings with shadow/hard enforce_mode. 7d shadow audit (2026-05-21): zero would-block events at any tier; peak utilization 23.7%; safe to flip.
- **RLS role split** (U145 → applied 2026-05-21 as part of U147): trading_role / personal_role / owner_role. Pen-test confirms cross-realm isolation. Consumer migration awaiting Jo's go.
- **Realm pivot** (U139): FAMILY → PERSONAL. 100% of CHECK constraints migrated (U146 cleaned the final partition stragglers in mart/raw/staging).

## What Phase 6 is anchored around

Operational close-the-loop. Phase 5 made the guardrails real. Phase 6 makes the *operational outputs* real:

- **Invoice match-rate to 95%+**: U150 found 1 orphan (was 63 at the U128 smoke test). The mechanism works; now harden vendor → product mapping (the U138 feedback loop already feeding rules).
- **Mortgage statement coverage to 95%+**: 21 missing quarters across 3 active loans (per v_mortgage_coverage). Drives the in-person packet.
- **Dashboard surfaces**: U149 wired tides + bank holidays + several dashboard slugs. Trail integration blocked on Jo providing correct API base; Reviews blocked on seeding listing URLs.
- **Hardening enforce-mode flip**: the budget cap becomes real once Jo signs off U148.

## Decision

Begin Phase 6 with three parallel tracks:

1. **Manual deliverables for Jo's next in-person session** (see `audits/u150-in-person-packet-2026-05-21.md`): mortgage statement scans, Trail base URL, review listing seeds, Dojo CSV uploads, Vault rotation check.
2. **Sign-offs pending** (low risk, awaiting Jo's green-light):
   - U147 T4: migrate service connection strings per consumer mapping.
   - U148 T3: flip quota enforce_mode to true.
3. **Pipeline robustness** (next sprint, U151): patch the noOp-skip / 0-rows-returned pattern in Invoice Pipeline + Nanny Pipeline (Gmail Ingest confirmed not vulnerable due to responseMode=onReceived).

## Risk

Low. Phase 6 is mostly surface/UI work + manual data ingest, not new architecture. The sign-off items have well-defined rollback paths.
