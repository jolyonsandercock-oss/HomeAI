-- V254 — M2 (refactor plan 2026-06-09): additive attribution columns.
-- Where the resolver's decision is recorded once a pipeline runs in `enforce`
-- mode (P5). Nullable + no default => instant, no table rewrite, no change to
-- source-of-truth semantics. Revert: DROP COLUMN (data is enrichment only).
BEGIN;

ALTER TABLE bank_transactions
  ADD COLUMN IF NOT EXISTS counterparty_id bigint REFERENCES financial_counterparty(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS counterparty_confidence real,
  ADD COLUMN IF NOT EXISTS counterparty_source text
    CHECK (counterparty_source IS NULL OR counterparty_source IN ('resolver','human','import'));

ALTER TABLE vendor_invoice_inbox
  ADD COLUMN IF NOT EXISTS counterparty_id bigint REFERENCES financial_counterparty(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS counterparty_confidence real,
  ADD COLUMN IF NOT EXISTS counterparty_source text
    CHECK (counterparty_source IS NULL OR counterparty_source IN ('resolver','human','import'));

CREATE INDEX IF NOT EXISTS bank_transactions_cp ON bank_transactions (counterparty_id) WHERE counterparty_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS vendor_invoice_inbox_cp ON vendor_invoice_inbox (counterparty_id) WHERE counterparty_id IS NOT NULL;

COMMIT;
