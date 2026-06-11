-- =============================================================================
-- V264 — resolver sweep: don't re-queue invoices Jo has already triaged
-- =============================================================================
-- Bug (2026-06-11 review): resolve_new_invoices skipped only OPEN queue rows.
-- ignore_review() flips the row to status='ignored' but leaves the invoice
-- counterparty_id NULL → the next sweep re-resolves it, abstains again, and
-- INSERTs a fresh OPEN row (the partial unique index only covers status='open').
-- Every ignored vendor would reappear in the queue twice an hour, forever.
--
-- Fix: skip invoices that have ANY review-queue row (open / ignored / resolved /
-- auto_closed). A human decision is terminal for the sweep; re-opening is an
-- explicit UI action, not something the cron should second-guess.
-- =============================================================================

BEGIN;

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
      UPDATE vendor_invoice_inbox
         SET counterparty_id        = (v_res->>'counterparty_id')::bigint,
             counterparty_confidence = (v_res->>'confidence')::real,
             counterparty_source     = 'resolver'
       WHERE id = v_inv.id;
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
  'Forward-only invoice resolver sweep (V264: skips invoices with ANY review-queue row so ignored items are not re-queued). Driven by scripts/u271-resolve-invoices.sh.';

COMMIT;
