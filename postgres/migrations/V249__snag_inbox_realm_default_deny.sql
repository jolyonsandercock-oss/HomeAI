-- V249 — default-deny the snag_inbox realm policy when realm is unset.
--
-- V237 created realm_isolation on snag_inbox with a permissive branch:
--   WHEN app.current_realm IS NULL OR '' THEN true   (allow ALL rows)
-- That was "safe" only because every consumer connected as the postgres
-- superuser (BYPASSRLS). The frontend (homeai_readonly role) reaches this
-- table, and until the frontend routes were fixed to set realm inside a
-- transaction (2026-06-07), snag reads/writes ran with realm = NULL → allow-all.
--
-- The frontend now sets realm via withRealm() on every snag path, so the only
-- non-superuser caller always provides a realm. This migration removes the
-- allow-all fallback: an unset realm now denies (matches owner-only intent).
--
-- SCOPE: snag_inbox ONLY. The same permissive-null pattern exists on ~14 other
-- realm policies (V65, V65b, V68, V73, V96, V168, V174, V206, V218, V219,
-- V225, V227, V228, V237). Those are NOT flipped here because they are still
-- read by non-realm-setting consumers; flipping them must be sequenced with the
-- U249 superuser→scoped-role migration (verify every consumer sets realm first,
-- or the flip returns 0 rows). Track that as its own migration.
--
-- Reversible: re-run V237's policy body.
BEGIN;

DROP POLICY IF EXISTS realm_isolation ON public.snag_inbox;

CREATE POLICY realm_isolation ON public.snag_inbox
  USING (
    CASE current_setting('app.current_realm', true)
      WHEN 'owner'    THEN true
      WHEN 'work'     THEN realm = ANY (ARRAY['work','shared'])
      WHEN 'personal' THEN realm = ANY (ARRAY['personal','shared'])
      ELSE false          -- NULL / '' / unknown → deny (was allow-all)
    END
  )
  WITH CHECK (
    CASE current_setting('app.current_realm', true)
      WHEN 'owner'    THEN true
      WHEN 'work'     THEN realm = ANY (ARRAY['work','shared'])
      WHEN 'personal' THEN realm = ANY (ARRAY['personal','shared'])
      ELSE false
    END
  );

COMMIT;
