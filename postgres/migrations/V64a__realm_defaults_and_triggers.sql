-- =============================================================================
-- V64a — Realm defaults + BEFORE INSERT triggers
-- =============================================================================
-- V64 added realm as NOT NULL with NO DEFAULT. Existing app code (n8n workflows,
-- Python pipelines) doesn't yet set `realm` on INSERT, so every cron run breaks.
--
-- This migration fixes that without enforcing anything new:
--   - Single-realm tables: ALTER COLUMN realm SET DEFAULT '<assigned realm>'.
--     INSERTs that don't specify realm get the right value automatically.
--   - Cross-realm tables: BEFORE INSERT trigger derives realm from entity_id
--     or account-of-receipt (mailbox).
--
-- This is still pure label phase. Nothing enforces visibility yet (that's R2).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Single-realm table defaults
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    rec RECORD;
    realm_map TEXT[][] := ARRAY[
        -- WORK
        ARRAY['accommodation_bookings','work'],
        ARRAY['accommodation_daily','work'],
        ARRAY['accommodation_daily_reports','work'],
        ARRAY['cafe_vendor_prompt_state','work'],
        ARRAY['caterbook_daily_snapshots','work'],
        ARRAY['caterbook_email_reports','work'],
        ARRAY['caterbook_observations','work'],
        ARRAY['epos_daily','work'],
        ARRAY['epos_daily_reports','work'],
        ARRAY['guest_reviews','work'],
        ARRAY['holiday_entitlement','work'],
        ARRAY['holiday_requests','work'],
        ARRAY['manager_notes','work'],
        ARRAY['review_drafts','work'],
        ARRAY['staff','work'],
        ARRAY['staff_meta','work'],
        ARRAY['supplier_invoice_history','work'],
        ARRAY['till_reconciliation','work'],
        ARRAY['touchoffice_department_sales','work'],
        ARRAY['touchoffice_fixed_totals','work'],
        ARRAY['touchoffice_plu_sales','work'],
        ARRAY['touchoffice_scrapes','work'],
        ARRAY['training_records','work'],
        ARRAY['vendor_category_rules','work'],
        ARRAY['workforce_departments','work'],
        ARRAY['workforce_locations','work'],
        ARRAY['workforce_shifts','work'],
        ARRAY['workforce_sync_log','work'],
        ARRAY['workforce_timesheets','work'],
        ARRAY['workforce_to_sales_map','work'],
        ARRAY['workforce_users','work'],
        ARRAY['workforce_wage_comparisons','work'],
        -- FAMILY
        ARRAY['child_events','family'],
        ARRAY['children','family'],
        ARRAY['garmin_body_metrics','family'],
        ARRAY['garmin_daily_summary','family'],
        ARRAY['garmin_sleep','family'],
        ARRAY['medical_history','family'],
        ARRAY['properties','family'],
        ARRAY['property_compliance','family'],
        ARRAY['property_market_log','family'],
        ARRAY['rent_payments','family'],
        ARRAY['tenancies','family'],
        ARRAY['vehicles','family'],
        -- OWNER
        ARRAY['ai_usage','owner'],
        ARRAY['audit_log','owner'],
        ARRAY['bot_feedback','owner'],
        ARRAY['bot_instructions','owner'],
        ARRAY['bot_sender_whitelist','owner'],
        ARRAY['dead_letter','owner'],
        ARRAY['dead_letter_archive','owner'],
        ARRAY['dreaming_heuristics','owner'],
        ARRAY['dreaming_runs','owner'],
        ARRAY['google_api_calls','owner'],
        ARRAY['model_inventory_log','owner'],
        ARRAY['query_rejections','owner'],
        ARRAY['query_whitelist','owner'],
        ARRAY['reconciliation_flags','owner'],
        ARRAY['security_audit_log','owner'],
        ARRAY['static_context','owner'],
        ARRAY['system_alerts','owner'],
        ARRAY['system_state','owner'],
        ARRAY['telegram_bot_state','owner'],
        ARRAY['telegram_outbox','owner'],
        ARRAY['vat_returns_log','owner'],
        -- SHARED
        ARRAY['entities','shared'],
        ARRAY['ops_constants','shared'],
        ARRAY['ops_thresholds','shared'],
        ARRAY['product_aliases','shared'],
        ARRAY['product_canonical','shared'],
        ARRAY['weather_daily','shared'],
        ARRAY['weather_forecast','shared']
    ];
    i INT;
BEGIN
    FOR i IN 1 .. array_length(realm_map, 1) LOOP
        EXECUTE format('ALTER TABLE public.%I ALTER COLUMN realm SET DEFAULT %L',
                       realm_map[i][1], realm_map[i][2]);
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Cross-realm BEFORE INSERT triggers
-- -----------------------------------------------------------------------------

-- Generic derivation function — by entity_id (1→work, 2/3/4→family, NULL→owner)
CREATE OR REPLACE FUNCTION realm_from_entity_id(p_entity_id INT) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN CASE
        WHEN p_entity_id = 1 THEN 'work'
        WHEN p_entity_id IN (2,3,4) THEN 'family'
        ELSE 'owner'
    END;
END $$;

-- Derivation by mailbox account
CREATE OR REPLACE FUNCTION realm_from_account(p_account TEXT) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN CASE
        WHEN p_account IN ('info','admin') THEN 'work'
        WHEN p_account IN ('jo','pounana') THEN 'family'
        WHEN p_account = 'bot' THEN 'owner'
        ELSE 'owner'
    END;
END $$;

-- emails: derive from account
CREATE OR REPLACE FUNCTION trg_emails_set_realm() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.realm IS NULL THEN
        NEW.realm := realm_from_account(NEW.account);
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_emails_realm ON emails;
CREATE TRIGGER trg_emails_realm BEFORE INSERT ON emails
    FOR EACH ROW EXECUTE FUNCTION trg_emails_set_realm();

-- email_attachments: follow parent email
CREATE OR REPLACE FUNCTION trg_email_attachments_set_realm() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_realm TEXT;
BEGIN
    IF NEW.realm IS NULL THEN
        SELECT realm INTO v_realm FROM emails WHERE id = NEW.email_id;
        NEW.realm := COALESCE(v_realm, 'owner');
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_email_attachments_realm ON email_attachments;
CREATE TRIGGER trg_email_attachments_realm BEFORE INSERT ON email_attachments
    FOR EACH ROW EXECUTE FUNCTION trg_email_attachments_set_realm();

-- email_tasks: follow parent email
CREATE OR REPLACE FUNCTION trg_email_tasks_set_realm() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_realm TEXT;
BEGIN
    IF NEW.realm IS NULL THEN
        SELECT realm INTO v_realm FROM emails WHERE id = NEW.email_id;
        NEW.realm := COALESCE(v_realm, 'owner');
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_email_tasks_realm ON email_tasks;
CREATE TRIGGER trg_email_tasks_realm BEFORE INSERT ON email_tasks
    FOR EACH ROW EXECUTE FUNCTION trg_email_tasks_set_realm();

-- Tables that derive from entity_id only: generic trigger
CREATE OR REPLACE FUNCTION trg_set_realm_from_entity_id() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.realm IS NULL THEN
        NEW.realm := realm_from_entity_id(NEW.entity_id);
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_documents_realm ON documents;
CREATE TRIGGER trg_documents_realm BEFORE INSERT ON documents
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_entity_id();

DROP TRIGGER IF EXISTS trg_events_realm ON events;
CREATE TRIGGER trg_events_realm BEFORE INSERT ON events
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_entity_id();

DROP TRIGGER IF EXISTS trg_invoices_realm ON invoices;
CREATE TRIGGER trg_invoices_realm BEFORE INSERT ON invoices
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_entity_id();

DROP TRIGGER IF EXISTS trg_bank_accounts_realm ON bank_accounts;
CREATE TRIGGER trg_bank_accounts_realm BEFORE INSERT ON bank_accounts
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_entity_id();

DROP TRIGGER IF EXISTS trg_bank_transactions_realm ON bank_transactions;
CREATE TRIGGER trg_bank_transactions_realm BEFORE INSERT ON bank_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_entity_id();

DROP TRIGGER IF EXISTS trg_companies_house_alerts_realm ON companies_house_alerts;
CREATE TRIGGER trg_companies_house_alerts_realm BEFORE INSERT ON companies_house_alerts
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_entity_id();

DROP TRIGGER IF EXISTS trg_cashflow_forecast_realm ON cashflow_forecast;
CREATE TRIGGER trg_cashflow_forecast_realm BEFORE INSERT ON cashflow_forecast
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_entity_id();

-- vendor_invoice_inbox: entity_id default is 1, account also present.
-- entity_id takes precedence (it's NOT NULL DEFAULT 1).
DROP TRIGGER IF EXISTS trg_vii_realm ON vendor_invoice_inbox;
CREATE TRIGGER trg_vii_realm BEFORE INSERT ON vendor_invoice_inbox
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_entity_id();

-- vendor_invoice_lines / due_date_extractions / invoice_feedback: follow parent invoice
CREATE OR REPLACE FUNCTION trg_set_realm_from_parent_invoice() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_realm TEXT;
BEGIN
    IF NEW.realm IS NULL THEN
        SELECT realm INTO v_realm FROM vendor_invoice_inbox WHERE id = NEW.invoice_id;
        NEW.realm := COALESCE(v_realm, 'owner');
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_vendor_invoice_lines_realm ON vendor_invoice_lines;
CREATE TRIGGER trg_vendor_invoice_lines_realm BEFORE INSERT ON vendor_invoice_lines
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_parent_invoice();

DROP TRIGGER IF EXISTS trg_due_date_extractions_realm ON due_date_extractions;
CREATE TRIGGER trg_due_date_extractions_realm BEFORE INSERT ON due_date_extractions
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_parent_invoice();

DROP TRIGGER IF EXISTS trg_invoice_feedback_realm ON invoice_feedback;
CREATE TRIGGER trg_invoice_feedback_realm BEFORE INSERT ON invoice_feedback
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_parent_invoice();

-- document_versions: follow parent document
CREATE OR REPLACE FUNCTION trg_document_versions_set_realm() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_realm TEXT;
BEGIN
    IF NEW.realm IS NULL THEN
        SELECT realm INTO v_realm FROM documents WHERE id = NEW.document_id;
        NEW.realm := COALESCE(v_realm, 'owner');
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_document_versions_realm ON document_versions;
CREATE TRIGGER trg_document_versions_realm BEFORE INSERT ON document_versions
    FOR EACH ROW EXECUTE FUNCTION trg_document_versions_set_realm();

-- companies_house_log: lookup by company_number
CREATE OR REPLACE FUNCTION trg_companies_house_log_set_realm() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_entity_id INT;
BEGIN
    IF NEW.realm IS NULL THEN
        SELECT id INTO v_entity_id FROM entities
         WHERE companies_house_number = NEW.company_number
         LIMIT 1;
        NEW.realm := realm_from_entity_id(v_entity_id);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_companies_house_log_realm ON companies_house_log;
CREATE TRIGGER trg_companies_house_log_realm BEFORE INSERT ON companies_house_log
    FOR EACH ROW EXECUTE FUNCTION trg_companies_house_log_set_realm();

COMMIT;

-- Smoke test: try an INSERT against touchoffice_scrapes without specifying realm.
-- (Outside the transaction so we can confirm the default sticks.)
\echo 'Smoke test: insert into touchoffice_scrapes without specifying realm…'
INSERT INTO touchoffice_scrapes
    (entity_id, site, report_date, widget, success)
VALUES (1, '__r1_smoke_test__', CURRENT_DATE, 'r1_test', true)
RETURNING id, realm;
DELETE FROM touchoffice_scrapes WHERE widget='r1_test' AND site='__r1_smoke_test__';
\echo 'Smoke test passed.'
