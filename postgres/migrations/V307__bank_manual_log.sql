-- V307 (2026-07-10) — bank manual recategorise audit log.
-- Backs the owner-only /bank dashboard page's "Recategorise" action
-- (main.py POST /api/bank/recategorise). Every manual category change is
-- appended here (old + new category, optional note) so the u294 category
-- work has a durable trail of human corrections separate from the
-- bank_transaction_rules engine. Append-only; no RLS needed (owner-only
-- API route already gates access at the app layer, matching the existing
-- /api/memory/* pattern).
SET app.current_entity='all'; SET app.current_realm='owner';

CREATE TABLE IF NOT EXISTS _bank_manual_log (
  id           bigserial PRIMARY KEY,
  txn_id       bigint NOT NULL REFERENCES bank_transactions(id),
  old_category text,
  new_category text NOT NULL,
  note         text,
  changed_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bank_manual_log_txn ON _bank_manual_log (txn_id);
