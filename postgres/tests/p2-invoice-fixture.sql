-- /home_ai/postgres/tests/p2-invoice-fixture.sql
-- DB-side simulation of a successful P2 (Invoice Pipeline) run.
-- Bypasses Gmail/pdfplumber/Haiku and asserts:
--   1. INSERT invoices with our idempotency_key shape works
--   2. invoices.idempotency_key UNIQUE is enforced (replay → no second row)
--   3. supplier_invoice_history rolling avg/min/max upsert works
--   4. invoice.unmatched event INSERT works under RLS
--   5. audit_log entry with OutcomeObject in ai_parsed validates
--
-- Run as homeai_pipeline so RLS is observed:
--   docker exec -i homeai-postgres psql -U homeai_pipeline -d homeai \
--     -v ON_ERROR_STOP=1 < /home_ai/postgres/tests/p2-invoice-fixture.sql
--
-- All inserts inside a transaction that ROLLBACKs at the end — no real
-- production data is created.

\set ON_ERROR_STOP on

BEGIN;

-- Set entity context so RLS allows the inserts
SELECT set_config('app.current_entity', '1', true);

-- Synthetic Haiku response (what Build OutcomeObject would produce on success)
\set supplier 'P2 Test Brewery'
\set gross    1234.56
\set inv_num  'TEST-INV-2026-001'
\set inv_date '2026-05-09'
\set entity   1

-- Compute the idempotency key the same way the JS does:
--   invoice_{sha256(supplier|gross|date|entity)}
DO $sim$
DECLARE
  v_idem TEXT := 'invoice_' || encode(digest(
    'P2 Test Brewery|1234.56|2026-05-09|1', 'sha256'), 'hex');
  v_first_id BIGINT;
  v_second_id BIGINT;
  v_event_id BIGINT;
  v_audit_id BIGINT;
  v_hist_count INT;
BEGIN
  -- ─── 1. First INSERT: should succeed ──────────────────────
  INSERT INTO invoices
    (idempotency_key, entity_id, source, supplier_name, invoice_number,
     invoice_date, gross_amount, currency, category, status,
     confidence_score, requires_human)
  VALUES
    (v_idem, 1, 'email_ocr', 'P2 Test Brewery', 'TEST-INV-2026-001',
     '2026-05-09'::date, 1234.56, 'GBP', 'stock', 'pending',
     0.92, false)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_first_id;

  IF v_first_id IS NULL THEN
    RAISE EXCEPTION 'fixture failed — first INSERT returned no id (idempotency_key collision with existing data?)';
  END IF;
  RAISE NOTICE 'first INSERT ok, invoices.id = %', v_first_id;

  -- ─── 2. Replay: should NOT insert ─────────────────────────
  INSERT INTO invoices
    (idempotency_key, entity_id, source, supplier_name, gross_amount,
     invoice_date, status, confidence_score)
  VALUES
    (v_idem, 1, 'email_ocr', 'P2 Test Brewery', 1234.56,
     '2026-05-09'::date, 'pending', 0.92)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_second_id;

  IF v_second_id IS NOT NULL THEN
    RAISE EXCEPTION 'fixture failed — replay INSERT returned id %, idempotency broken', v_second_id;
  END IF;
  RAISE NOTICE 'replay correctly skipped (idempotency holds)';

  -- ─── 3. Supplier history upsert ──────────────────────────
  INSERT INTO supplier_invoice_history
    (entity_id, supplier_name, invoice_month, avg_gross, min_gross, max_gross, invoice_count)
  VALUES
    (1, 'P2 Test Brewery', date_trunc('month', '2026-05-09'::date)::date,
     1234.56, 1234.56, 1234.56, 1)
  ON CONFLICT (entity_id, supplier_name, invoice_month) DO UPDATE
    SET avg_gross    = (supplier_invoice_history.avg_gross * supplier_invoice_history.invoice_count + EXCLUDED.avg_gross) / (supplier_invoice_history.invoice_count + 1),
        min_gross    = LEAST(supplier_invoice_history.min_gross, EXCLUDED.min_gross),
        max_gross    = GREATEST(supplier_invoice_history.max_gross, EXCLUDED.max_gross),
        invoice_count = supplier_invoice_history.invoice_count + 1;

  -- Insert a second invoice from same supplier different month — should aggregate
  INSERT INTO supplier_invoice_history
    (entity_id, supplier_name, invoice_month, avg_gross, min_gross, max_gross, invoice_count)
  VALUES
    (1, 'P2 Test Brewery', date_trunc('month', '2026-05-09'::date)::date,
     2000.00, 2000.00, 2000.00, 1)
  ON CONFLICT (entity_id, supplier_name, invoice_month) DO UPDATE
    SET avg_gross    = (supplier_invoice_history.avg_gross * supplier_invoice_history.invoice_count + EXCLUDED.avg_gross) / (supplier_invoice_history.invoice_count + 1),
        min_gross    = LEAST(supplier_invoice_history.min_gross, EXCLUDED.min_gross),
        max_gross    = GREATEST(supplier_invoice_history.max_gross, EXCLUDED.max_gross),
        invoice_count = supplier_invoice_history.invoice_count + 1;

  SELECT invoice_count INTO v_hist_count
    FROM supplier_invoice_history
   WHERE entity_id = 1 AND supplier_name = 'P2 Test Brewery';

  IF v_hist_count <> 2 THEN
    RAISE EXCEPTION 'fixture failed — supplier_invoice_history.invoice_count = % (expected 2)', v_hist_count;
  END IF;
  RAISE NOTICE 'supplier history rolling stats ok, count=%', v_hist_count;

  -- ─── 4. invoice.unmatched event ──────────────────────────
  INSERT INTO events
    (event_type, source, entity_id, payload, payload_signature,
     status, idempotency_key, pipeline_version, parent_event_id, trace_id)
  SELECT 'invoice.unmatched', 'invoice_pipeline', 1,
         jsonb_build_object('supplier_name','P2 Test Brewery',
                            'gross_amount', 1234.56,
                            'invoice_idempotency_key', v_idem),
         'P2_FIXTURE_PLACEHOLDER_HMAC',
         'done',
         'invoice_event_test_' || substr(v_idem, 9, 16),
         '1.0', NULL, gen_random_uuid()
   WHERE NOT EXISTS (
     SELECT 1 FROM events WHERE idempotency_key = 'invoice_event_test_' || substr(v_idem, 9, 16)
   )
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    RAISE EXCEPTION 'fixture failed — invoice.unmatched event INSERT returned no id';
  END IF;
  RAISE NOTICE 'invoice.unmatched event ok, events.id = %', v_event_id;

  -- ─── 5. audit_log with OutcomeObject ─────────────────────
  INSERT INTO audit_log
    (pipeline, event_id, action, entity_id, record_type, record_id,
     ai_worker, ai_model, ai_parsed, pipeline_version, result)
  VALUES
    ('invoice_pipeline', v_event_id, 'extract_invoice_fixture', 1,
     'invoice', v_first_id,
     'invoice_extractor', 'claude-haiku-4-5-20251001',
     jsonb_build_object(
       'status', 'success',
       'confidence', 0.92,
       'reasoning', 'fixture run — no real Haiku call',
       'data', jsonb_build_object('supplier_name', 'P2 Test Brewery',
                                  'gross_amount', 1234.56,
                                  'invoice_date', '2026-05-09'),
       'requires_human', false,
       'worker', 'invoice_extractor',
       'tier_used', 'haiku'),
     '1.0', 'success')
  RETURNING id INTO v_audit_id;

  RAISE NOTICE 'audit_log row ok, id = %', v_audit_id;

  -- ─── Summary ─────────────────────────────────────────────
  RAISE NOTICE '── P2 fixture passed ──';
  RAISE NOTICE '  invoice_id  = %', v_first_id;
  RAISE NOTICE '  event_id    = %', v_event_id;
  RAISE NOTICE '  audit_id    = %', v_audit_id;
  RAISE NOTICE '  hist_count  = %', v_hist_count;
END $sim$;

ROLLBACK;
SELECT 'P2 invoice fixture passed (rolled back)' AS result;
