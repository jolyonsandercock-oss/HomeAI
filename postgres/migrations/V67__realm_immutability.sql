-- V67: Realm immutability + home_ai.realm_override() chokepoint.
--
-- Once a row is tagged with its realm at insert (V64a triggers + R5
-- producer-side tagging from U53), no consumer should be able to flip
-- it via a plain UPDATE. The only legitimate path is through the
-- OWNER-credentialled home_ai.realm_override() function, which:
--   1. Refuses to run unless app.current_realm = 'owner'
--   2. Sets a session sentinel (app.realm_override_active) that the
--      BEFORE UPDATE triggers below explicitly look for
--   3. Performs the UPDATE
--   4. Inserts an audit_log row capturing actor / table / id / old /
--      new / reason
--   5. Clears the sentinel
--
-- Per the U53 sprint plan + [[project_realm_split]] (SPEC §2.5
-- "Misdirected invoice" edge case): re-classification of a row's
-- realm is rare, always intentional, always logged.

BEGIN;

-- ── 1. Override chokepoint ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION home_ai.realm_override(
    p_table     TEXT,
    p_id        BIGINT,
    p_new_realm TEXT,
    p_reason    TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_old_realm TEXT;
    v_caller    TEXT;
BEGIN
    IF current_setting('app.current_realm', true) IS DISTINCT FROM 'owner' THEN
        RAISE EXCEPTION 'realm_override_requires_owner'
            USING DETAIL = format('app.current_realm = %L', current_setting('app.current_realm', true));
    END IF;

    IF p_new_realm NOT IN ('owner','work','family','shared') THEN
        RAISE EXCEPTION 'realm_override_invalid_target'
            USING DETAIL = format('p_new_realm = %L', p_new_realm);
    END IF;

    IF p_table NOT IN ('emails','email_attachments','events','documents',
                       'vendor_invoice_inbox','vendor_invoice_lines',
                       'bank_transactions') THEN
        RAISE EXCEPTION 'realm_override_table_not_allowed'
            USING DETAIL = format('p_table = %L', p_table);
    END IF;

    -- Capture old realm for audit. events is partitioned so we need the
    -- composite key; plain emails/inbox use id.
    EXECUTE format('SELECT realm FROM %I WHERE id = $1 LIMIT 1', p_table)
        INTO v_old_realm USING p_id;

    IF v_old_realm IS NULL THEN
        RAISE EXCEPTION 'realm_override_row_not_found'
            USING DETAIL = format('%I.id = %L', p_table, p_id);
    END IF;

    IF v_old_realm = p_new_realm THEN
        RETURN;  -- no-op
    END IF;

    -- Open the gate, perform the update, slam it shut.
    PERFORM set_config('app.realm_override_active', '1', true);
    EXECUTE format('UPDATE %I SET realm = $1 WHERE id = $2', p_table)
        USING p_new_realm, p_id;
    PERFORM set_config('app.realm_override_active', '', true);

    v_caller := coalesce(current_setting('app.current_user', true), session_user);

    INSERT INTO audit_log (pipeline, action, record_type, record_id,
                           ai_parsed, result, realm)
    VALUES ('realm_override', 'realm_override', p_table, p_id,
            jsonb_build_object(
                'old_realm', v_old_realm,
                'new_realm', p_new_realm,
                'reason',    p_reason,
                'actor',     v_caller
            ),
            'success', 'owner');
END $$;

COMMENT ON FUNCTION home_ai.realm_override(TEXT, BIGINT, TEXT, TEXT) IS
$$Owner-only chokepoint for mutating a row's realm. Refuses unless
app.current_realm = 'owner'. Sets app.realm_override_active = '1'
around the UPDATE so BEFORE UPDATE triggers let it through. Inserts
an audit_log row. See SPEC §2.5 "Misdirected invoice" edge case.$$;

-- ── 2. Immutability trigger function ───────────────────────────────
CREATE OR REPLACE FUNCTION home_ai.trg_realm_immutable() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.realm IS DISTINCT FROM OLD.realm
       AND coalesce(current_setting('app.realm_override_active', true), '') <> '1' THEN
        RAISE EXCEPTION 'realm_immutable_without_override'
            USING DETAIL = format('%I.id = %L: realm %L -> %L blocked. '
                                  'Use home_ai.realm_override() as OWNER.',
                                  TG_TABLE_NAME, NEW.id, OLD.realm, NEW.realm);
    END IF;
    RETURN NEW;
END $$;

-- ── 3. Attach to every realm-bearing table that has a stable PK ────
DROP TRIGGER IF EXISTS trg_emails_realm_immutable ON emails;
CREATE TRIGGER trg_emails_realm_immutable BEFORE UPDATE ON emails
    FOR EACH ROW EXECUTE FUNCTION home_ai.trg_realm_immutable();

DROP TRIGGER IF EXISTS trg_email_attachments_realm_immutable ON email_attachments;
CREATE TRIGGER trg_email_attachments_realm_immutable BEFORE UPDATE ON email_attachments
    FOR EACH ROW EXECUTE FUNCTION home_ai.trg_realm_immutable();

DROP TRIGGER IF EXISTS trg_events_realm_immutable ON events;
CREATE TRIGGER trg_events_realm_immutable BEFORE UPDATE ON events
    FOR EACH ROW EXECUTE FUNCTION home_ai.trg_realm_immutable();

DROP TRIGGER IF EXISTS trg_documents_realm_immutable ON documents;
CREATE TRIGGER trg_documents_realm_immutable BEFORE UPDATE ON documents
    FOR EACH ROW EXECUTE FUNCTION home_ai.trg_realm_immutable();

DROP TRIGGER IF EXISTS trg_vendor_invoice_inbox_realm_immutable ON vendor_invoice_inbox;
CREATE TRIGGER trg_vendor_invoice_inbox_realm_immutable BEFORE UPDATE ON vendor_invoice_inbox
    FOR EACH ROW EXECUTE FUNCTION home_ai.trg_realm_immutable();

DROP TRIGGER IF EXISTS trg_vendor_invoice_lines_realm_immutable ON vendor_invoice_lines;
CREATE TRIGGER trg_vendor_invoice_lines_realm_immutable BEFORE UPDATE ON vendor_invoice_lines
    FOR EACH ROW EXECUTE FUNCTION home_ai.trg_realm_immutable();

DROP TRIGGER IF EXISTS trg_bank_transactions_realm_immutable ON bank_transactions;
CREATE TRIGGER trg_bank_transactions_realm_immutable BEFORE UPDATE ON bank_transactions
    FOR EACH ROW EXECUTE FUNCTION home_ai.trg_realm_immutable();

COMMIT;

-- ── 4. Smoke (manual, post-apply) ──────────────────────────────────
-- Block direct UPDATE:
--   UPDATE emails SET realm='family' WHERE id=<a work row>;
--   → ERROR: realm_immutable_without_override
--
-- Override path:
--   SET LOCAL app.current_realm='owner';
--   SELECT home_ai.realm_override('emails', <id>, 'family', 'misdirected-invoice');
--   → succeeds; audit_log row visible
--
-- Non-owner override:
--   SET LOCAL app.current_realm='work';
--   SELECT home_ai.realm_override('emails', <id>, 'work', 'test');
--   → ERROR: realm_override_requires_owner
