# U233 — Realm classification accuracy

**Realm**: cross-cutting (data quality). **Remote vs in-person**: 100% remote.
**Risk**: low — realm only affects RLS visibility + work-realm aggregates; the
retag is reversible and was applied conservatively.

**Why this sprint exists**: invoices were systematically mis-tagged
`realm='personal'`, distorting work-realm COGS/GP and the U232 coverage signal,
and (once U147 Phase A made RLS real) *hiding* genuine business invoices from
the work surface. Surfaced during U147 + U232.

## Root cause (verified 2026-05-31)

`scripts/projA/ladder.py::derive_realm(account, entity_id)` checked the
**receiving inbox before the entity**: `account='jo'` → `personal`, overriding
`entity_id=1` (ARTL/work). So any pub invoice Jo received/forwarded from his
own address was tagged personal regardless of being an ARTL business cost.

Evidence: all 76 mis-tagged invoices were `entity_id=1` + `account='jo'`, and
the vendors were overwhelmingly business — RCC Roofing (£47k), Western Supply,
Howden Joinery, Trelawney Fire & Security, Reg Hambly Insurance, RoomPriceGenie
(hotel software), etc.

**Note:** the *bank* realms are NOT mis-classified — `bank_transactions.realm`
correctly follows account ownership (ATR trading accounts = work, personal/AREL
accounts = personal). The earlier "bank mis-tagged" hypothesis was wrong.

## Done (2026-05-31)

1. **Fixed `derive_realm`** — entity is now authoritative (entity 1 → work
   before any account fallback). Prevents recurrence. (ladder.py)
2. **Reclassified existing data** — 74 invoices + 147 lines moved
   `personal → work` (entity_id=1, excluding the two genuinely-personal vendors
   below). Work realm: 487 → 550 invoices, £92k → £147k line-net spend.
3. **Verified**: work KPIs reflect the correction; personal toggle still returns
   0 to a work request (U147 Phase A RLS cap intact); U232 coverage improved
   (Jan 2026 flipped false-`low` → `ok`).

## Decisions (resolved by Jo 2026-05-31)

1. **St Joseph's School (£8,436) + Math Academy ($49)** — confirmed
   personal/family. **DONE**: entity corrected `1 → 4` (Family); realm stays
   `personal` (the only valid personal-side realm for `set_realm`; RLS
   `personal` sees family+personal+shared). They now sit outside work COGS.
2. **AREL (entity 2) realm** — **decision: keep `personal` for now**, defer the
   realm-model question. `derive_realm` already maps entity 2 → personal; no
   change. Revisit if/when AREL needs its own work surface (own-realm = own
   sprint).

**Final state**: 620 work/entity-1 invoices, 2 personal/entity-4. Sprint
complete bar the carried-over refinements below.

## Findings carried to other sprints

- **ARTL bank feed is sparse** (U232): the ATR trading account has only 81 txns
  / £16k outflow vs £147k of captured work invoices — pub suppliers are largely
  paid from the personal account / card / DD, not the trading account. So a
  bank-anchored COGS coverage ratio for ARTL is not viable from the trading
  account alone; it would need supplier-payment identification across accounts.
  U232 Track 3 increment 2 stays deferred (different reason than first thought).
- **Coverage view counts capex** (U232 T3): `v_cogs_capture_coverage.captured_cogs`
  sums all `line_net` incl. capex/repairs (RCC Roofing £47k spiked March).
  Refine to exclude non-COGS categories so the completeness flag isn't skewed by
  one-off capital spend.

## Follow-ups (not yet done)
- Resolve the two held decisions above; correct St Joseph's/Math Academy entity.
- Optional: a vendor→realm rule layer (extend `vendor_category_rules`) so realm
  derivation can override entity for known cross-realm vendors, rather than
  relying solely on the upstream entity classifier.
