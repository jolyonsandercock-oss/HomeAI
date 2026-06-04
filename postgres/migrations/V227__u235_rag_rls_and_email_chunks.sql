-- V227 — U235: (b) RLS defence-in-depth + (c) wire email_chunk into the corpus.
--
-- Context: build-dashboard connects as the postgres SUPERUSER, which BYPASSES RLS,
-- so the /api/research/ask realm middleware gates access but not row visibility.
-- The endpoint is being changed to filter by realm explicitly (surgical). These RLS
-- policies are defence-in-depth for any non-superuser caller (frontend readonly role).

-- ── (c) FTS support for email_chunk ─────────────────────────────────────────
ALTER TABLE email_rag_chunks
  ADD COLUMN IF NOT EXISTS tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('english', COALESCE(chunk_text, ''))) STORED;
CREATE INDEX IF NOT EXISTS idx_email_rag_chunks_tsv ON email_rag_chunks USING gin(tsv);

-- ── cosine similarity over real[] (rerank helper; lexical-first keeps it cheap) ──
CREATE OR REPLACE FUNCTION home_ai.cosine_sim(a real[], b real[])
RETURNS double precision
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $fn$
  SELECT CASE WHEN d = 0 THEN 0 ELSE dot / d END
  FROM (
    SELECT sum(x*y) AS dot,
           sqrt(sum(x*x)) * sqrt(sum(y*y)) AS d
    FROM unnest(a, b) AS t(x, y)
  ) s;
$fn$;
COMMENT ON FUNCTION home_ai.cosine_sim(real[], real[]) IS
  'U235: cosine similarity for nomic-embed-text real[] vectors (rerank lexical candidates).';

-- ── (b) RLS on search_vectors (mirror email_rag_chunks: open base + realm narrow) ──
ALTER TABLE search_vectors ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS base_access ON search_vectors;
CREATE POLICY base_access ON search_vectors FOR SELECT USING (true);

DROP POLICY IF EXISTS realm_isolation ON search_vectors;
CREATE POLICY realm_isolation ON search_vectors AS RESTRICTIVE USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner'    THEN true
    WHEN current_setting('app.current_realm', true) = 'work'     THEN realm = ANY (ARRAY['work','shared'])
    WHEN current_setting('app.current_realm', true) = 'personal' THEN realm = ANY (ARRAY['personal','shared'])
    WHEN current_setting('app.current_realm', true) IS NULL
      OR current_setting('app.current_realm', true) = ''         THEN true
    ELSE false
  END);
GRANT SELECT ON search_vectors TO homeai_readonly;

-- ── (c) Unified corpus: email_chunk (sanitised) REPLACES whole-email 'email' ────
-- Dropping the raw 'email' branch also closes a latent Rule-4 gap (it embedded raw
-- body_text). Invoice branch stays enriched (V226). source_id for email_chunk =
-- email_rag_chunks.id, matching the search_vectors rows written by u235.
CREATE OR REPLACE VIEW v_research_corpus AS
 SELECT 'email_chunk'::text AS source_table,
    c.id AS source_id,
    c.tsv AS ts,
    e.subject AS title,
    c.chunk_text AS body,
    e.received_at AS event_at,
    e.account,
    c.entity_id,
    c.realm
   FROM email_rag_chunks c
     JOIN emails e ON e.id = c.email_id
UNION ALL
 SELECT 'invoice_line'::text AS source_table,
    vil.id AS source_id,
    to_tsvector('english', concat_ws(' ', vil.description, vii.vendor_name)) AS ts,
    concat_ws(' — ',
      vil.description,
      NULLIF(vii.vendor_name, ''),
      CASE WHEN vil.line_gross IS NOT NULL THEN 'gross £' || vil.line_gross::text END
    ) AS title,
    concat_ws(' · ',
      NULLIF(vii.vendor_name, ''),
      CASE WHEN vil.qty        IS NOT NULL THEN 'qty ' || vil.qty::text END,
      CASE WHEN vil.unit_price IS NOT NULL THEN 'unit £' || vil.unit_price::text END,
      CASE WHEN vil.line_net   IS NOT NULL THEN 'net £' || vil.line_net::text END,
      CASE WHEN vil.line_vat   IS NOT NULL THEN 'vat £' || vil.line_vat::text END,
      CASE WHEN vil.line_gross IS NOT NULL THEN 'gross £' || vil.line_gross::text END,
      CASE WHEN vil.department   IS NOT NULL THEN 'dept ' || vil.department END,
      CASE WHEN vii.invoice_date IS NOT NULL THEN 'invoice ' || vii.invoice_date::text END
    ) AS body,
    vii.invoice_date::timestamptz AS event_at,
    vii.account,
    vii.entity_id,
    vii.realm
   FROM vendor_invoice_lines vil
     JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id
UNION ALL
 SELECT 'document'::text AS source_table,
    d.id AS source_id,
    d.ocr_tsv AS ts,
    d.title,
    d.ocr_text AS body,
    d.created_at AS event_at,
    NULL::text AS account,
    d.entity_id,
    d.realm
   FROM documents d
  WHERE d.ocr_tsv IS NOT NULL;
