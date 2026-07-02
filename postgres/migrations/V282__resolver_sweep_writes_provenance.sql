-- =============================================================================
-- V282 — wire anchor + resolution_log provenance writes into the automatic
-- invoice resolver sweep (were never landing)
-- =============================================================================
-- Root cause (found 2026-07-02, both tables at 0 rows despite 16,773 invoices
-- auto-resolved with counterparty_id set): V259's own comment says it plainly —
--   "Attribution + provenance live on the invoice row. The resolution_log /
--    revalidation lifecycle layer is a deliberate follow-on ... not wired in
--    this v1 sweep."
-- That follow-on was never shipped. The ONLY writers of counterparty_anchor /
-- counterparty_resolution_log are home_ai.confirm_resolution() and
-- home_ai.upsert_anchor(), both driven from the human review-page action
-- (services/build-dashboard/main.py) — never from the cron sweep
-- (home_ai.resolve_new_invoices, scripts/u271-resolve-invoices.sh). Every
-- automatic decision re-derives from scratch (domain/trigram) every run and
-- leaves zero audit trail. Stage 1 of home_ai.resolve_counterparty() (the
-- fast, collision-safe "strong anchor" path) can therefore never fire on the
-- automatic path either, since nothing ever populates counterparty_anchor.
--
-- Fix (minimal, additive to the 'resolve' branch only — no change to decision
-- logic, thresholds, or the vendor_invoice_inbox UPDATE):
--   1. Every automatic resolve now also upserts a 'valid' counterparty_resolution_log
--      row (confirmed_by = 'resolver:sweep', same fingerprint formula used by
--      resolve_counterparty()/confirm_resolution() so future human confirms of
--      the identical evidence shape hit the same ON CONFLICT key).
--   2. Resolutions at stage 'domain_exact' or 'strong_anchor' (both already
--      collision-checked as unique-in-scope by resolve_counterparty) additionally
--      promote/refresh a 'strong' email_domain identity anchor via the existing
--      home_ai.upsert_anchor() lifecycle function. 'trigram' and 'learned_alias'
--      stages are deliberately NOT promoted to anchors — trigram is a fuzzy
--      string match and should not become a durable "strong" identity signal.
--
-- Historical 15,938 backfilled/16,773 auto-resolved rows are NOT retroactively
-- given fabricated provenance here — we cannot know what evidence the sweep
-- actually saw at the time of each historical run, only what it would decide
-- today. This migration only changes behaviour for resolutions FROM NOW ON.
-- =============================================================================

BEGIN;

-- Second bug found while verifying the fix live (2026-07-02): counterparty_anchor's
-- source_system CHECK (V252) enumerates bank/dext/xero/email/icrtouch/caterbook/manual
-- but omits 'vendor_invoice_inbox' — the actual source_system value the invoice
-- resolver pipeline uses everywhere (review-queue rows, resolution evidence, and
-- both the anchor-promotion call added below AND the pre-existing human
-- home_ai.confirm_resolution(..., p_promote_anchor=true) path). Anchor promotion for
-- ANY invoice-sourced resolution was DOA from V252 onward; it was simply never
-- exercised because confirm_resolution has zero historical invocations. Widen the
-- constraint rather than rename the value everywhere it's already used.
ALTER TABLE counterparty_anchor DROP CONSTRAINT IF EXISTS counterparty_anchor_source_system_check;
ALTER TABLE counterparty_anchor ADD CONSTRAINT counterparty_anchor_source_system_check
  CHECK (source_system = ANY (ARRAY['bank','dext','xero','email','icrtouch','caterbook','manual','vendor_invoice_inbox']));

CREATE OR REPLACE FUNCTION home_ai.resolve_new_invoices(p_limit int DEFAULT 500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $fn$
DECLARE
  v_mode      text;
  v_watermark bigint;
  v_inv       record;
  v_ev        jsonb;
  v_res       jsonb;
  v_processed int := 0;
  v_resolved  int := 0;
  v_queued    int := 0;
  v_skipped   int := 0;
  v_cp_id     bigint;
  v_stage     text;
  v_raw       text;
  v_domain    text;
  v_acct      text;
  v_fp        text;
BEGIN
  PERFORM set_config('app.current_entity', 'all',   true);
  PERFORM set_config('app.current_realm',  'owner', true);

  v_mode := btrim(COALESCE((SELECT value #>> '{}' FROM static_context WHERE key = 'resolver.mode'), 'shadow'), '"');
  v_watermark := COALESCE((SELECT (value #>> '{}')::bigint FROM static_context WHERE key = 'resolver.invoice_watermark_id'), 0);

  FOR v_inv IN
    SELECT vii.id, vii.vendor_name, vii.vendor_domain, vii.account, vii.entity_id, vii.realm
      FROM vendor_invoice_inbox vii
     WHERE vii.id > v_watermark
       AND vii.counterparty_id IS NULL
       AND COALESCE(vii.is_statement, false) = false
       -- V264: ANY queue row (any status) means already queued or human-triaged.
       AND NOT EXISTS (
         SELECT 1 FROM counterparty_resolution_review_queue q
          WHERE q.source_system = 'vendor_invoice_inbox'
            AND q.source_ref = vii.id::text)
     ORDER BY vii.id
     LIMIT p_limit
  LOOP
    v_processed := v_processed + 1;
    v_ev := jsonb_build_object(
      'raw_counterparty',     v_inv.vendor_name,
      'email_domain',         v_inv.vendor_domain,
      'invoice_account_code', v_inv.account,
      'entity_hint',          v_inv.entity_id::text,
      'realm',                v_inv.realm,
      'source_system',        'vendor_invoice_inbox');

    IF v_mode = 'shadow' THEN
      PERFORM home_ai.resolve_shadow('vendor_invoice_inbox', v_inv.id::text, v_ev);
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_res := home_ai.resolve_counterparty(v_ev);

    IF v_res->>'decision' = 'resolve' THEN
      v_cp_id := (v_res->>'counterparty_id')::bigint;
      v_stage := v_res->>'stage';

      UPDATE vendor_invoice_inbox
         SET counterparty_id        = v_cp_id,
             counterparty_confidence = (v_res->>'confidence')::real,
             counterparty_source     = 'resolver'
       WHERE id = v_inv.id;

      -- V282: provenance writes the resolve_counterparty() stage funnel was
      -- designed to feed, so a future audit can show WHY each invoice
      -- resolved and so stage-1 strong-anchor lookups actually have anchors
      -- to find. Same fingerprint formula as resolve_counterparty()/
      -- confirm_resolution() so the ON CONFLICT key lines up with any
      -- human confirmation of the identical evidence shape.
      v_raw    := nullif(lower(btrim(coalesce(v_ev->>'raw_counterparty',''))), '');
      v_domain := nullif(lower(btrim(coalesce(v_ev->>'email_domain',''))), '');
      v_acct   := coalesce(v_ev->>'source_account','');
      v_fp := (SELECT coalesce(string_agg(t||':'||v,'|' ORDER BY t||':'||v),'') FROM (VALUES
                ('email_domain',v_domain),
                ('invoice_account_code', nullif(upper(btrim(coalesce(v_ev->>'invoice_account_code',''))),'')),
                ('bank_reference', nullif(coalesce(v_ev->>'bank_reference',''),'')),
                ('vat_number', nullif(coalesce(v_ev->>'vat_number',''),''))
              ) a(t,v) WHERE v IS NOT NULL);

      INSERT INTO counterparty_resolution_log
        (source_system, source_account, raw_counterparty_normalized, anchor_fingerprint,
         counterparty_id, entity_id, realm, confirmed_by, validation_status, evidence_json,
         registry_fingerprint)
      VALUES
        ('vendor_invoice_inbox', v_acct, coalesce(v_raw,''), v_fp,
         v_cp_id, v_inv.entity_id, v_inv.realm, 'resolver:sweep', 'valid', v_ev,
         home_ai.fc_fingerprint(v_cp_id))
      ON CONFLICT (source_system, source_account, raw_counterparty_normalized, anchor_fingerprint)
        WHERE validation_status = 'valid'
      DO UPDATE SET counterparty_id = EXCLUDED.counterparty_id,
                    evidence_json = EXCLUDED.evidence_json,
                    registry_fingerprint = EXCLUDED.registry_fingerprint,
                    confirmed_by = EXCLUDED.confirmed_by,
                    confirmed_at = now(), updated_at = now();

      -- Only promote a durable "strong" identity anchor for the two stages
      -- that are already unique-in-scope / collision-checked by
      -- resolve_counterparty(). Fuzzy trigram / already-aliased matches
      -- must not become strong anchors.
      IF v_stage IN ('domain_exact','strong_anchor') AND v_domain IS NOT NULL THEN
        PERFORM home_ai.upsert_anchor('email_domain','identity', v_domain, 'global', '',
                  v_cp_id, v_inv.entity_id, v_inv.realm, 'vendor_invoice_inbox', 'strong');
      END IF;

      v_resolved := v_resolved + 1;

    ELSIF v_mode = 'review' THEN
      INSERT INTO counterparty_resolution_review_queue
        (source_system, source_ref, entity_id, realm, evidence_json, abstain_reason,
         top_candidates, suggested_action)
      VALUES
        ('vendor_invoice_inbox', v_inv.id::text, v_inv.entity_id, v_inv.realm, v_ev,
         v_res->>'reason',
         COALESCE(v_res->'top_candidates', '[]'::jsonb),
         CASE WHEN v_res ? 'top_candidates' THEN 'confirm_existing' ELSE 'create_new' END)
      ON CONFLICT (source_system, source_ref) WHERE status = 'open' DO NOTHING;
      v_queued := v_queued + 1;

    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'mode', v_mode, 'watermark', v_watermark, 'limit', p_limit,
    'processed', v_processed, 'resolved', v_resolved,
    'queued', v_queued, 'skipped', v_skipped);
END;
$fn$;

COMMENT ON FUNCTION home_ai.resolve_new_invoices(int) IS
  'Forward-only invoice resolver sweep (V264: skips invoices with ANY review-queue row; V282: writes counterparty_resolution_log + promotes strong anchors for domain_exact/strong_anchor resolutions). Driven by scripts/u271-resolve-invoices.sh.';

COMMIT;
