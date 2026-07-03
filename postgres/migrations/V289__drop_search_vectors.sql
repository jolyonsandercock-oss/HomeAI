-- V289 — drop search_vectors (2026-07-03, Jo's call in the perf follow-up).
-- 152k ollama embeddings / 760MB incl. indexes: writers (u65-build-research-
-- embeddings.sh, u235-embed-email-chunks.sh, u235b-embed-invoices-docs.sh)
-- were never scheduled, data stopped growing 2026-06-04, and no code read it
-- (3 index scans lifetime). Derived data — rebuildable by re-running the
-- embed scripts against ollama if semantic search is revived.
-- email_rag_chunks is NOT touched (live consumer: counterparty dossiers).

DROP TABLE IF EXISTS search_vectors;
