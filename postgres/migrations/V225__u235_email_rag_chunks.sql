-- V225 — U235 Cultural Memory, Stage 0
-- Full-body sanitiser (no truncation) + sanitised/chunked email corpus for RAG.
-- Faithful to services/google-fetch/main.py _sanitise() MINUS the 2000-char cap.

-- ── Reusable full-body sanitiser ────────────────────────────────────────────
-- HTML-strip, redact known prompt-injection phrases, collapse whitespace. No cap.
CREATE OR REPLACE FUNCTION home_ai.sanitise_full(t text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $fn$
DECLARE c text;
BEGIN
  IF t IS NULL THEN RETURN NULL; END IF;
  c := t;
  -- drop script/style/comment blocks (their contents survive plain tag-stripping)
  c := regexp_replace(c, '<style[^>]*>.*?</style>',   ' ', 'gi');
  c := regexp_replace(c, '<script[^>]*>.*?</script>', ' ', 'gi');
  c := regexp_replace(c, '<!--.*?-->',                ' ', 'gi');
  -- strip remaining HTML tags
  c := regexp_replace(c, '<[^>]*>', ' ', 'g');
  -- redact known prompt-injection phrases (mirror _SANITISE_PATTERNS)
  c := regexp_replace(c, 'ignore\s+(all\s+)?previous\s+instructions?', '[REDACTED]', 'gi');
  c := regexp_replace(c, 'forget\s+(all\s+)?instructions?',            '[REDACTED]', 'gi');
  c := regexp_replace(c, 'you\s+are\s+now\s+',                         '[REDACTED]', 'gi');
  c := regexp_replace(c, 'new\s+instructions?:',                       '[REDACTED]', 'gi');
  c := regexp_replace(c, 'system\s*:',                                 '[REDACTED]', 'gi');
  c := regexp_replace(c, '\[/?INST\]',                                 '[REDACTED]', 'gi');
  c := regexp_replace(c, '<\|im_(start|end)\|>',                       '[REDACTED]', 'gi');
  c := regexp_replace(c, '###\s*instruction',                          '[REDACTED]', 'gi');
  c := regexp_replace(c, 'act\s+as\s+',                                '[REDACTED]', 'gi');
  c := regexp_replace(c, 'pretend\s+(you\s+are|to\s+be)\s+',           '[REDACTED]', 'gi');
  c := regexp_replace(c, 'override\s+(the\s+)?system',                 '[REDACTED]', 'gi');
  c := regexp_replace(c, 'jailbreak',                                  '[REDACTED]', 'gi');
  -- collapse whitespace
  c := regexp_replace(c, '\s+', ' ', 'g');
  RETURN NULLIF(btrim(c), '');
END;
$fn$;

COMMENT ON FUNCTION home_ai.sanitise_full(text) IS
  'U235: non-truncating prompt-injection sanitiser for RAG. Mirrors _sanitise() without the 2000-char cap.';

-- ── Sanitised + chunked email corpus ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS email_rag_chunks (
  id          bigserial PRIMARY KEY,
  email_id    bigint NOT NULL REFERENCES emails(id) ON DELETE CASCADE,
  chunk_index int    NOT NULL,
  chunk_text  text   NOT NULL,
  char_start  int    NOT NULL,
  char_end    int    NOT NULL,
  realm       text   NOT NULL,
  entity_id   int,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (email_id, chunk_index),
  CONSTRAINT email_rag_chunks_realm_check
    CHECK (realm = ANY (ARRAY['owner','work','personal','shared']))
);

CREATE INDEX IF NOT EXISTS idx_email_rag_chunks_email ON email_rag_chunks(email_id);
CREATE INDEX IF NOT EXISTS idx_email_rag_chunks_realm ON email_rag_chunks(realm);

-- RLS: mirror emails.realm_isolation (RESTRICTIVE). owner sees all; work/personal scoped;
-- no realm set -> all (consistent with emails; the worker also filters explicitly).
ALTER TABLE email_rag_chunks ENABLE ROW LEVEL SECURITY;

-- PERMISSIVE base grant — a RESTRICTIVE policy alone denies everything (it can only
-- narrow). emails pairs its RESTRICTIVE realm policy with a PERMISSIVE entity policy;
-- here the realm policy is the only gate we need, so the base grant is open and the
-- RESTRICTIVE realm_isolation below does the actual filtering.
DROP POLICY IF EXISTS base_access ON email_rag_chunks;
CREATE POLICY base_access ON email_rag_chunks FOR SELECT USING (true);

DROP POLICY IF EXISTS realm_isolation ON email_rag_chunks;
CREATE POLICY realm_isolation ON email_rag_chunks AS RESTRICTIVE USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner'    THEN true
    WHEN current_setting('app.current_realm', true) = 'work'     THEN realm = ANY (ARRAY['work','shared'])
    WHEN current_setting('app.current_realm', true) = 'personal' THEN realm = ANY (ARRAY['personal','shared'])
    WHEN current_setting('app.current_realm', true) IS NULL
      OR current_setting('app.current_realm', true) = ''         THEN true
    ELSE false
  END);

-- read access for the dashboard read-only role (RLS still applies on top)
GRANT SELECT ON email_rag_chunks TO homeai_readonly;
