-- V290 (2026-07-04) — index hygiene from the round-2 perf audit.
-- Applied live via CREATE/DROP INDEX CONCURRENTLY; recorded here for schema
-- history (see also V289 search_vectors drop). ~213MB of dead index reclaimed
-- + the single biggest remaining per-minute full-scan eliminated.

-- (1) postgres-exporter's emails_review_queue metric ran a full seq scan of
--     the 79MB emails heap every 60s (78,740 rows -> ~6,569 match). Partial
--     index makes it an index-only scan. Predicate MUST match the exporter
--     query in monitoring/postgres-exporter-queries.yaml exactly.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_emails_review_queue
  ON emails(id)
  WHERE requires_human OR confidence_score < 0.75 OR NOT processed OR action_required;

-- (2) idx_emails_body_fts (177MB GIN on to_tsvector('english', body_text)):
--     superseded by the stored tsv column + idx_emails_tsv (tsv-first search,
--     perf pass 1). idx_scan=0 AND verified no code anywhere uses the
--     to_tsvector(body_text) pattern (services/scripts/n8n all grepped).
DROP INDEX CONCURRENTLY IF EXISTS idx_emails_body_fts;

-- (3) google_api_calls is a write-only API-call log; idx_gac_scope (20MB) and
--     idx_gac_account (16MB) had idx_scan=0 AND zero code paths filter by
--     scope/account. Pure write-amplification.
DROP INDEX CONCURRENTLY IF EXISTS idx_gac_scope;
DROP INDEX CONCURRENTLY IF EXISTS idx_gac_account;

-- NOT dropped (flagged, needs care): idx_emails_body_trgm (159MB, ILIKE
-- fallback path), idx_vii_pdf_text_trgm / idx_vil_* (invoice-text SEARCH
-- indexes — idx_scan=0 is unreliable here because stats reset ~2026-07-02;
-- same trap as idx_emails_tsv which is live but shows 0). Keep until a
-- no-code-path proof across a full stats window.
