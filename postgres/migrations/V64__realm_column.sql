-- =============================================================================
-- V64 — Realm-split label phase (R1)
-- =============================================================================
-- Adds a `realm` column to every Home AI domain table.
--
-- Realm values:
--   'owner'  — OWNER realm only (audit_log, dreaming_*, system_state, etc.)
--             Visible only to a user whose identity maps to OWNER.
--   'work'   — WORK realm + OWNER (pub/cafe operational data, entity_id=1).
--             Visible to WORK identities and OWNER.
--   'family' — FAMILY realm + OWNER (entities 2/3/4 — estates, personal,
--             family). Visible to FAMILY identities and OWNER.
--   'shared' — visible to all realms (lookup/reference data — weather,
--             entities, ops_thresholds, etc.).
--
-- NO ENFORCEMENT in this migration. Pure label. RLS conversion is R2.
-- =============================================================================
--
-- Identity → realm mapping (from static_context.gmail.accounts):
--   info    (info@malthousetintagel.com,    pub_shared)         → work
--   admin   (admin@malthousetintagel.com,   pub_admin)          → work
--   jo      (jolyon.sandercock@gmail.com,   primary_personal)   → family
--   pounana (pounana@gmail.com,             secondary_personal) → family
--   bot     (jolyboxbot@gmail.com,          system_outbound)    → owner
--
-- Note: Jo-the-person logs in as OWNER and sees everything. Jo-the-mailbox
-- (jo) tags incoming mail as `family` because that is the content type;
-- OWNER includes family by superset semantics.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Step 1: Build the realm-assignment map for simple single-realm tables.
-- -----------------------------------------------------------------------------

CREATE TEMP TABLE _realm_assignment (
    table_name TEXT PRIMARY KEY,
    realm      TEXT NOT NULL CHECK (realm IN ('owner','work','family','shared'))
);

INSERT INTO _realm_assignment (table_name, realm) VALUES
    -- WORK (pub / cafe / ice-cream — entity 1)
    ('accommodation_bookings',        'work'),
    ('accommodation_daily',           'work'),
    ('accommodation_daily_reports',   'work'),
    ('cafe_vendor_prompt_state',      'work'),
    ('caterbook_daily_snapshots',     'work'),
    ('caterbook_email_reports',       'work'),
    ('caterbook_observations',        'work'),
    ('epos_daily',                    'work'),
    ('epos_daily_reports',            'work'),
    ('guest_reviews',                 'work'),
    ('holiday_entitlement',           'work'),
    ('holiday_requests',              'work'),
    ('manager_notes',                 'work'),
    ('review_drafts',                 'work'),
    ('staff',                         'work'),
    ('staff_meta',                    'work'),
    ('supplier_invoice_history',      'work'),
    ('till_reconciliation',           'work'),
    ('touchoffice_department_sales',  'work'),
    ('touchoffice_fixed_totals',      'work'),
    ('touchoffice_plu_sales',         'work'),
    ('touchoffice_scrapes',           'work'),
    ('training_records',              'work'),
    ('vendor_category_rules',         'work'),
    ('workforce_departments',         'work'),
    ('workforce_locations',           'work'),
    ('workforce_shifts',              'work'),
    ('workforce_sync_log',            'work'),
    ('workforce_timesheets',          'work'),
    ('workforce_to_sales_map',        'work'),
    ('workforce_users',               'work'),
    ('workforce_wage_comparisons',    'work'),

    -- FAMILY (estates / personal / family — entities 2/3/4)
    ('child_events',                  'family'),
    ('children',                      'family'),
    ('garmin_body_metrics',           'family'),
    ('garmin_daily_summary',          'family'),
    ('garmin_sleep',                  'family'),
    ('medical_history',               'family'),
    ('properties',                    'family'),
    ('property_compliance',           'family'),
    ('property_market_log',           'family'),
    ('rent_payments',                 'family'),
    ('tenancies',                     'family'),
    ('vehicles',                      'family'),

    -- OWNER (platform-internal — visible only to OWNER realm)
    ('ai_usage',                      'owner'),
    ('audit_log',                     'owner'),
    ('bot_feedback',                  'owner'),
    ('bot_instructions',              'owner'),
    ('bot_sender_whitelist',          'owner'),
    ('dead_letter',                   'owner'),
    ('dead_letter_archive',           'owner'),
    ('dreaming_heuristics',           'owner'),
    ('dreaming_runs',                 'owner'),
    ('google_api_calls',              'owner'),
    ('model_inventory_log',           'owner'),
    ('query_rejections',              'owner'),
    ('query_whitelist',               'owner'),
    ('reconciliation_flags',          'owner'),
    ('security_audit_log',            'owner'),
    ('static_context',                'owner'),
    ('system_alerts',                 'owner'),
    ('system_state',                  'owner'),
    ('telegram_bot_state',            'owner'),
    ('telegram_outbox',               'owner'),
    ('vat_returns_log',               'owner'),

    -- SHARED (lookup / reference — readable by all realms)
    ('entities',                      'shared'),
    ('ops_constants',                 'shared'),
    ('ops_thresholds',                'shared'),
    ('product_aliases',               'shared'),
    ('product_canonical',             'shared'),
    ('weather_daily',                 'shared'),
    ('weather_forecast',              'shared');

-- -----------------------------------------------------------------------------
-- Step 2: Apply realm column to simple single-realm tables.
-- Order: ADD nullable → UPDATE → SET NOT NULL → ADD CHECK.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT table_name, realm FROM _realm_assignment ORDER BY table_name LOOP
        -- Skip if column already exists (idempotent re-run)
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name   = r.table_name
               AND column_name  = 'realm'
        ) THEN
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN realm TEXT', r.table_name);
            EXECUTE format('UPDATE public.%I SET realm = %L', r.table_name, r.realm);
            EXECUTE format('ALTER TABLE public.%I ALTER COLUMN realm SET NOT NULL', r.table_name);
            EXECUTE format(
                'ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (realm IN (''owner'',''work'',''family'',''shared''))',
                r.table_name, r.table_name || '_realm_check'
            );
        END IF;
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Step 3: Cross-realm tables — realm derived per-row.
-- -----------------------------------------------------------------------------

-- emails: realm derived from `account` (the source mailbox identity)
ALTER TABLE emails ADD COLUMN realm TEXT;
UPDATE emails SET realm = CASE
    WHEN account IN ('info','admin') THEN 'work'
    WHEN account IN ('jo','pounana') THEN 'family'
    WHEN account = 'bot'             THEN 'owner'
    ELSE 'owner'  -- defensive default; will be caught by NOT NULL
END;
ALTER TABLE emails ALTER COLUMN realm SET NOT NULL;
ALTER TABLE emails ADD CONSTRAINT emails_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- email_attachments: follow parent email
ALTER TABLE email_attachments ADD COLUMN realm TEXT;
UPDATE email_attachments ea
   SET realm = e.realm
  FROM emails e
 WHERE ea.email_id = e.id;
-- Orphans (shouldn't exist; FK should prevent) default to owner
UPDATE email_attachments SET realm = 'owner' WHERE realm IS NULL;
ALTER TABLE email_attachments ALTER COLUMN realm SET NOT NULL;
ALTER TABLE email_attachments ADD CONSTRAINT email_attachments_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- email_tasks: follow parent email
ALTER TABLE email_tasks ADD COLUMN realm TEXT;
UPDATE email_tasks et
   SET realm = e.realm
  FROM emails e
 WHERE et.email_id = e.id;
UPDATE email_tasks SET realm = 'owner' WHERE realm IS NULL;
ALTER TABLE email_tasks ALTER COLUMN realm SET NOT NULL;
ALTER TABLE email_tasks ADD CONSTRAINT email_tasks_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- documents: realm from entity_id (1→work, 2/3/4→family, NULL→owner)
ALTER TABLE documents ADD COLUMN realm TEXT;
UPDATE documents SET realm = CASE
    WHEN entity_id = 1 THEN 'work'
    WHEN entity_id IN (2,3,4) THEN 'family'
    ELSE 'owner'
END;
ALTER TABLE documents ALTER COLUMN realm SET NOT NULL;
ALTER TABLE documents ADD CONSTRAINT documents_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- document_versions: follow parent document
ALTER TABLE document_versions ADD COLUMN realm TEXT;
UPDATE document_versions dv
   SET realm = d.realm
  FROM documents d
 WHERE dv.document_id = d.id;
UPDATE document_versions SET realm = 'owner' WHERE realm IS NULL;
ALTER TABLE document_versions ALTER COLUMN realm SET NOT NULL;
ALTER TABLE document_versions ADD CONSTRAINT document_versions_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- events: partitioned by created_at. ADD COLUMN on parent propagates.
ALTER TABLE events ADD COLUMN realm TEXT;
UPDATE events SET realm = CASE
    WHEN entity_id = 1 THEN 'work'
    WHEN entity_id IN (2,3,4) THEN 'family'
    ELSE 'owner'
END;
ALTER TABLE events ALTER COLUMN realm SET NOT NULL;
ALTER TABLE events ADD CONSTRAINT events_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- vendor_invoice_inbox: entity_id default is 1, so most rows are work.
-- Account-of-receipt as a secondary signal for any entity_id-NULL rows.
ALTER TABLE vendor_invoice_inbox ADD COLUMN realm TEXT;
UPDATE vendor_invoice_inbox SET realm = CASE
    WHEN entity_id = 1 THEN 'work'
    WHEN entity_id IN (2,3,4) THEN 'family'
    WHEN account IN ('info','admin') THEN 'work'
    WHEN account IN ('jo','pounana') THEN 'family'
    ELSE 'owner'
END;
ALTER TABLE vendor_invoice_inbox ALTER COLUMN realm SET NOT NULL;
ALTER TABLE vendor_invoice_inbox ADD CONSTRAINT vendor_invoice_inbox_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- vendor_invoice_lines: follow parent invoice
ALTER TABLE vendor_invoice_lines ADD COLUMN realm TEXT;
UPDATE vendor_invoice_lines vl
   SET realm = vi.realm
  FROM vendor_invoice_inbox vi
 WHERE vl.invoice_id = vi.id;
UPDATE vendor_invoice_lines SET realm = 'owner' WHERE realm IS NULL;
ALTER TABLE vendor_invoice_lines ALTER COLUMN realm SET NOT NULL;
ALTER TABLE vendor_invoice_lines ADD CONSTRAINT vendor_invoice_lines_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- due_date_extractions: follow parent invoice
ALTER TABLE due_date_extractions ADD COLUMN realm TEXT;
UPDATE due_date_extractions dde
   SET realm = vi.realm
  FROM vendor_invoice_inbox vi
 WHERE dde.invoice_id = vi.id;
UPDATE due_date_extractions SET realm = 'owner' WHERE realm IS NULL;
ALTER TABLE due_date_extractions ALTER COLUMN realm SET NOT NULL;
ALTER TABLE due_date_extractions ADD CONSTRAINT due_date_extractions_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- invoice_feedback: follow parent invoice
ALTER TABLE invoice_feedback ADD COLUMN realm TEXT;
UPDATE invoice_feedback ifb
   SET realm = vi.realm
  FROM vendor_invoice_inbox vi
 WHERE ifb.invoice_id = vi.id;
UPDATE invoice_feedback SET realm = 'owner' WHERE realm IS NULL;
ALTER TABLE invoice_feedback ALTER COLUMN realm SET NOT NULL;
ALTER TABLE invoice_feedback ADD CONSTRAINT invoice_feedback_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- invoices: entity_id based
ALTER TABLE invoices ADD COLUMN realm TEXT;
UPDATE invoices SET realm = CASE
    WHEN entity_id = 1 THEN 'work'
    WHEN entity_id IN (2,3,4) THEN 'family'
    ELSE 'owner'
END;
ALTER TABLE invoices ALTER COLUMN realm SET NOT NULL;
ALTER TABLE invoices ADD CONSTRAINT invoices_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- bank_accounts: entity_id based
ALTER TABLE bank_accounts ADD COLUMN realm TEXT;
UPDATE bank_accounts SET realm = CASE
    WHEN entity_id = 1 THEN 'work'
    WHEN entity_id IN (2,3,4) THEN 'family'
    ELSE 'owner'
END;
ALTER TABLE bank_accounts ALTER COLUMN realm SET NOT NULL;
ALTER TABLE bank_accounts ADD CONSTRAINT bank_accounts_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- bank_transactions: entity_id based
ALTER TABLE bank_transactions ADD COLUMN realm TEXT;
UPDATE bank_transactions SET realm = CASE
    WHEN entity_id = 1 THEN 'work'
    WHEN entity_id IN (2,3,4) THEN 'family'
    ELSE 'owner'
END;
ALTER TABLE bank_transactions ALTER COLUMN realm SET NOT NULL;
ALTER TABLE bank_transactions ADD CONSTRAINT bank_transactions_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- companies_house_log: keyed on company_number, derive via JOIN to entities
ALTER TABLE companies_house_log ADD COLUMN realm TEXT;
UPDATE companies_house_log chl
   SET realm = CASE
     WHEN e.id = 1 THEN 'work'
     WHEN e.id IN (2,3,4) THEN 'family'
     ELSE 'owner'
   END
  FROM entities e
 WHERE e.companies_house_number = chl.company_number;
-- Rows whose company_number isn't yet mapped to an entity default to owner.
UPDATE companies_house_log SET realm = 'owner' WHERE realm IS NULL;
ALTER TABLE companies_house_log ALTER COLUMN realm SET NOT NULL;
ALTER TABLE companies_house_log ADD CONSTRAINT companies_house_log_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- companies_house_alerts: entity_id based
ALTER TABLE companies_house_alerts ADD COLUMN realm TEXT;
UPDATE companies_house_alerts SET realm = CASE
    WHEN entity_id = 1 THEN 'work'
    WHEN entity_id IN (2,3,4) THEN 'family'
    ELSE 'owner'
END;
ALTER TABLE companies_house_alerts ALTER COLUMN realm SET NOT NULL;
ALTER TABLE companies_house_alerts ADD CONSTRAINT companies_house_alerts_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- cashflow_forecast: entity_id based
ALTER TABLE cashflow_forecast ADD COLUMN realm TEXT;
UPDATE cashflow_forecast SET realm = CASE
    WHEN entity_id = 1 THEN 'work'
    WHEN entity_id IN (2,3,4) THEN 'family'
    ELSE 'owner'
END;
ALTER TABLE cashflow_forecast ALTER COLUMN realm SET NOT NULL;
ALTER TABLE cashflow_forecast ADD CONSTRAINT cashflow_forecast_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- -----------------------------------------------------------------------------
-- Step 4: Indexes on realm for tables > 10k rows (RLS performance prep).
-- -----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_emails_realm                       ON emails (realm);
CREATE INDEX IF NOT EXISTS idx_events_realm                       ON events (realm);
CREATE INDEX IF NOT EXISTS idx_audit_log_realm                    ON audit_log (realm);
CREATE INDEX IF NOT EXISTS idx_touchoffice_fixed_totals_realm     ON touchoffice_fixed_totals (realm);
CREATE INDEX IF NOT EXISTS idx_touchoffice_department_sales_realm ON touchoffice_department_sales (realm);
CREATE INDEX IF NOT EXISTS idx_touchoffice_plu_sales_realm        ON touchoffice_plu_sales (realm);
CREATE INDEX IF NOT EXISTS idx_touchoffice_scrapes_realm          ON touchoffice_scrapes (realm);
CREATE INDEX IF NOT EXISTS idx_workforce_shifts_realm             ON workforce_shifts (realm);
CREATE INDEX IF NOT EXISTS idx_caterbook_observations_realm       ON caterbook_observations (realm);
CREATE INDEX IF NOT EXISTS idx_vendor_invoice_inbox_realm         ON vendor_invoice_inbox (realm);

-- -----------------------------------------------------------------------------
-- Step 5: Verification view — v_realm_audit
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_realm_audit AS
SELECT
    n.nspname || '.' || c.relname AS qualified_name,
    c.relname AS table_name,
    EXISTS (
        SELECT 1 FROM information_schema.columns col
         WHERE col.table_schema = 'public'
           AND col.table_name = c.relname
           AND col.column_name = 'realm'
    ) AS has_realm_column,
    c.reltuples::bigint AS approx_rows
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public'
   AND c.relkind = 'r'  -- regular tables only (not partitions, not views)
 ORDER BY c.relname;

COMMENT ON VIEW v_realm_audit IS
    'R1: lists every public.* base table and whether it has the realm column. '
    'A new home_ai-domain table without realm=true is a lint failure.';

-- -----------------------------------------------------------------------------
-- Step 6: Final verification — no Home AI domain table is missing realm.
-- (Hard-coded allowlist of n8n / Open WebUI / model-evaluator framework
-- tables that are exempt from the realm requirement. These belong to
-- third-party tools sharing the public schema.)
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    missing_count INT;
    missing_tables TEXT;
BEGIN
    WITH framework_exempt AS (
        SELECT unnest(ARRAY[
            -- n8n framework
            'ai_builder_temporary_workflow','annotation_tag_entity','auth_identity',
            'auth_provider_sync_history','binary_data','chat_hub_agent_tools',
            'chat_hub_agents','chat_hub_messages','chat_hub_session_tools',
            'chat_hub_sessions','chat_hub_tools','command_log','credential_dependency',
            'credentials_entity','data_table','data_table_column','deployment_key',
            'diagnostic_history','dynamic_credential_entry','dynamic_credential_resolver',
            'dynamic_credential_user_entry','event_destinations','event_idempotency_keys',
            'execution_annotation_tags','execution_annotations','execution_data',
            'execution_entity','execution_metadata','folder','folder_tag',
            'insights_by_period','insights_metadata','insights_raw','installed_nodes',
            'installed_packages','instance_ai_iteration_logs','instance_ai_messages',
            'instance_ai_observational_memory','instance_ai_resources',
            'instance_ai_run_snapshots','instance_ai_threads','instance_ai_workflow_snapshots',
            'instance_version_history','invalid_auth_token','migrations',
            'oauth_access_tokens','oauth_authorization_codes','oauth_clients',
            'oauth_refresh_tokens','oauth_user_consents','processed_data','project',
            'project_relation','project_secrets_provider_access','role',
            'role_mapping_rule','role_mapping_rule_project','role_scope','scope',
            'secrets_provider_connection','settings','shared_credentials',
            'shared_workflow','tag_entity','test_case_execution','test_run',
            'token_exchange_jti','trusted_key','trusted_key_source','user',
            'user_api_keys','user_favorites','variables','webhook_entity',
            'workflow_builder_session','workflow_dependency','workflow_entity',
            'workflow_history','workflow_publish_history','workflow_published_version',
            'workflow_statistics','workflows_tags',
            -- model-evaluator / OWUI / LiteLLM (managed by separate tools)
            'benchmark_results','model_recommendations','model_registry',
            'model_scan_log','model_scores','model_usage_history'
        ]) AS table_name
    )
    SELECT COUNT(*), string_agg(c.relname, ', ' ORDER BY c.relname)
      INTO missing_count, missing_tables
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
       AND c.relname NOT IN (SELECT table_name FROM framework_exempt)
       AND NOT EXISTS (
           SELECT 1 FROM information_schema.columns col
            WHERE col.table_schema = 'public'
              AND col.table_name = c.relname
              AND col.column_name = 'realm'
       );

    IF missing_count > 0 THEN
        RAISE EXCEPTION 'V64 verification failed: % home_ai domain table(s) missing realm column: %',
            missing_count, missing_tables;
    END IF;

    RAISE NOTICE 'V64 verification PASS: every home_ai domain table has realm column.';
END $$;

DROP TABLE _realm_assignment;

COMMIT;
