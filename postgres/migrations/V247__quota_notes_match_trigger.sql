-- V247 — fix stale quota_allocations.notes so they match what the
-- home_ai.ai_usage_autopopulate trigger ACTUALLY maps task_type -> business_priority.
-- The old notes drifted: P0 omitted invoice extraction (the trigger puts it in P0,
-- alongside bank/recon/compliance/cashflow/legal), and P1 still claimed "invoice
-- extraction" (the trigger maps P1 = email/digest/report). Cosmetic only — the
-- trigger mapping (the source of truth) is unchanged.
-- Reversible: restore the prior notes strings (kept in git history of V171/this file).
BEGIN;

UPDATE quota_allocations SET notes =
  'Floor — cannot be cannibalised by P1/P2/P3. Invoice extract/validate, bank '
  'categorise, reconciliation, bot-responder, compliance, cashflow, legal.'
 WHERE business_priority = 'P0';

UPDATE quota_allocations SET notes =
  'Email classify/route, digest generation, report parsing.'
 WHERE business_priority = 'P1';

UPDATE quota_allocations SET notes =
  'RAG queries, knowledge lookups.'
 WHERE business_priority = 'P2';

UPDATE quota_allocations SET notes =
  'Review drafting, dreaming, news digest, child classify — exploratory/low-stakes.'
 WHERE business_priority = 'P3';

COMMIT;
