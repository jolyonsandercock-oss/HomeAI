-- V300 (2026-07-05, U295) — statement reconciliation engine.
--
-- Supplier STATEMENTS (is_statement=true) list every invoice the supplier
-- issued for the period. Parsing those lines and matching them against
-- vendor_invoice_inbox gives a TRUE per-supplier capture rate + a concrete
-- missing-invoice list (as opposed to the "did we ingest N emails" proxy).
--
-- statement_recon_lines: one row per invoice/credit/payment line parsed out
-- of a statement PDF. Idempotent by design: scripts/u295-statement-recon.py
-- DELETEs a statement_id's existing rows before re-inserting (so re-parsing a
-- statement is a clean replace), and only ever SELECTs statement_id values
-- that are NOT YET present in this table for its "what's new today" query —
-- that's the "only parse NEW statements" gate, no extra state table needed.
--
-- match_method:
--   'invoice_number' — normalised statement ref matched an inbox invoice's
--                       own ref (extracted from subject/pdf text per vendor).
--   'date_amount'    — no ref match; invoice_date +/-3d AND gross +/-0.02 did.
--   'unmatched'      — no candidate found at all (a genuinely missing invoice,
--                       OR a payment/credit line we don't try to match).
--   'duplicate'      — this statement_id's content (vendor + line-set) is
--                       identical to an already-processed statement_id (the
--                       "same statement forwarded twice" case flagged
--                       throughout stmt-sweep-20260705); recorded as a single
--                       marker row (invoice_ref = 'DUP-OF-<id>', matched_invoice_id
--                       NULL) purely so the statement_id counts as "processed"
--                       and is never re-parsed. Excluded from the capture view.
CREATE TABLE IF NOT EXISTS statement_recon_lines (
  id                 BIGSERIAL PRIMARY KEY,
  statement_id       BIGINT NOT NULL REFERENCES vendor_invoice_inbox(id) ON DELETE CASCADE,
  vendor_key         TEXT NOT NULL,
  invoice_ref        TEXT,
  line_date          DATE,
  line_amount        NUMERIC(12,2),
  matched_invoice_id BIGINT REFERENCES vendor_invoice_inbox(id),
  match_method       TEXT NOT NULL CHECK (match_method IN ('invoice_number','date_amount','unmatched','duplicate')),
  realm              TEXT NOT NULL CHECK (realm = ANY (ARRAY['owner','work','personal','shared'])),
  parsed_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  run_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_srl_statement   ON statement_recon_lines (statement_id);
CREATE INDEX IF NOT EXISTS idx_srl_vendor_key  ON statement_recon_lines (vendor_key);
CREATE INDEX IF NOT EXISTS idx_srl_matched     ON statement_recon_lines (matched_invoice_id) WHERE matched_invoice_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_srl_unmatched   ON statement_recon_lines (vendor_key) WHERE match_method = 'unmatched';

-- realm follows the parent statement row (derived, never independently set).
CREATE OR REPLACE FUNCTION trg_set_realm_from_parent_statement() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_realm TEXT;
BEGIN
    IF NEW.realm IS NULL THEN
        SELECT realm INTO v_realm FROM vendor_invoice_inbox WHERE id = NEW.statement_id;
        NEW.realm := COALESCE(v_realm, 'owner');
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_srl_realm ON statement_recon_lines;
CREATE TRIGGER trg_srl_realm BEFORE INSERT ON statement_recon_lines
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_parent_statement();

ALTER TABLE statement_recon_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS entity_isolation_srl ON statement_recon_lines;
CREATE POLICY entity_isolation_srl ON statement_recon_lines
  USING (EXISTS (
    SELECT 1 FROM vendor_invoice_inbox v
     WHERE v.id = statement_recon_lines.statement_id
       AND CASE
             WHEN current_setting('app.current_entity', true) = 'all' THEN true
             WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN v.entity_id = current_setting('app.current_entity', true)::int
             ELSE false
           END
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM vendor_invoice_inbox v
     WHERE v.id = statement_recon_lines.statement_id
       AND CASE
             WHEN current_setting('app.current_entity', true) = 'all' THEN true
             WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN v.entity_id = current_setting('app.current_entity', true)::int
             ELSE false
           END
  ));

DROP POLICY IF EXISTS realm_isolation_srl ON statement_recon_lines;
CREATE POLICY realm_isolation_srl ON statement_recon_lines AS RESTRICTIVE
  USING (
    CASE
      WHEN current_setting('app.current_realm', true) = 'owner' THEN true
      WHEN current_setting('app.current_realm', true) = 'work' THEN realm = ANY (ARRAY['work','shared'])
      WHEN current_setting('app.current_realm', true) = 'personal' THEN realm = ANY (ARRAY['personal','shared'])
      WHEN current_setting('app.current_realm', true) IS NULL OR current_setting('app.current_realm', true) = '' THEN true
      ELSE false
    END
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON statement_recon_lines TO homeai_pipeline;
GRANT SELECT ON statement_recon_lines TO homeai_readonly;
GRANT SELECT ON statement_recon_lines TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE statement_recon_lines_id_seq TO homeai_pipeline;

-- ── Per-vendor capture-rate view (the deliverable Jo asked to see) ─────────
CREATE OR REPLACE VIEW v_statement_capture_rate AS
SELECT
  vendor_key                                                       AS vendor,
  count(DISTINCT statement_id)                                     AS statements,
  count(*) FILTER (WHERE match_method <> 'duplicate')               AS lines,
  count(*) FILTER (WHERE matched_invoice_id IS NOT NULL)            AS matched,
  count(*) FILTER (WHERE match_method = 'unmatched')                AS missing,
  round(
    100.0 * count(*) FILTER (WHERE matched_invoice_id IS NOT NULL)
    / NULLIF(count(*) FILTER (WHERE match_method <> 'duplicate'), 0), 1
  )                                                                 AS capture_pct,
  coalesce(sum(line_amount) FILTER (WHERE match_method = 'unmatched'), 0) AS missing_value
FROM statement_recon_lines
GROUP BY vendor_key
ORDER BY missing_value DESC NULLS LAST;

GRANT SELECT ON v_statement_capture_rate TO homeai_readonly;
GRANT SELECT ON v_statement_capture_rate TO metabase_app;

-- ── Autoflag log: "is this actually a statement?" cheap sweep evidence ─────
-- U295 T3: any is_statement=false row whose subject says "statement" AND
-- whose already-extracted PDF text carries a statement marker gets flipped
-- (evidence-logged here, never silently). Backup-table discipline: this is
-- the append-only audit trail equivalent of a _backup_* snapshot, kept as a
-- real table (not a one-off _backup_*) because the sweep runs daily.
CREATE TABLE IF NOT EXISTS _stmt_autoflag_log (
  id          BIGSERIAL PRIMARY KEY,
  invoice_id  BIGINT NOT NULL REFERENCES vendor_invoice_inbox(id),
  flipped_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  evidence    TEXT
);
CREATE INDEX IF NOT EXISTS idx_stmt_autoflag_invoice ON _stmt_autoflag_log (invoice_id);

GRANT SELECT, INSERT ON _stmt_autoflag_log TO homeai_pipeline;
GRANT SELECT ON _stmt_autoflag_log TO homeai_readonly;
GRANT USAGE, SELECT ON SEQUENCE _stmt_autoflag_log_id_seq TO homeai_pipeline;
