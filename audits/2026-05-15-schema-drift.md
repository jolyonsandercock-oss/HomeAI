# Schema drift audit

Generated 2026-05-15T20:30:55+01:00. Read-only against live; scratch DB homeai_drift_1778873441 created and dropped.

Compares live schema vs replay of postgres/init-db.sql + migrations/V*.sql.

- Lines starting with `-` (and not `---`): present in MIGRATIONS but NOT in live (migration not applied / table dropped manually).
- Lines starting with `+` (and not `+++`): present in LIVE but NOT in migrations (manual ALTER / drift).

## Result: ⚠ drift detected

```diff
--- /tmp/replay-schema.sql	2026-05-15 20:30:55.849932030 +0100
+++ /tmp/live-schema.sql	2026-05-15 20:30:41.529657257 +0100
@@ -1,5 +1,7 @@
 
-\restrict cT3idpXyJhx9TSdVLxxziGjI8V6TMCESCfhDjFkr6bqdRVqkuHE3YK0wxwzsTr3
+\restrict zKHT7Tz1SYviASdTxtrQggqX3rLnPfeGAE43bQET7ybuFdYnQmHN0Ns5MaS5mwA
+
+CREATE SCHEMA home_ai;
 
 CREATE SCHEMA mart;
 
@@ -7,15 +9,131 @@
 
 CREATE SCHEMA staging;
 
-CREATE FUNCTION mart.refresh_cash_variance_day(window_days integer DEFAULT 30) RETURNS integer
+CREATE FUNCTION home_ai.realm_override(p_table text, p_id bigint, p_new_realm text, p_reason text) RETURNS void
+    LANGUAGE plpgsql SECURITY DEFINER
+    AS $_$
+DECLARE
+    v_old_realm TEXT;
+    v_caller    TEXT;
+BEGIN
+    IF current_setting('app.current_realm', true) IS DISTINCT FROM 'owner' THEN
+        RAISE EXCEPTION 'realm_override_requires_owner'
+            USING DETAIL = format('app.current_realm = %L', current_setting('app.current_realm', true));
+    END IF;
+
+    IF p_new_realm NOT IN ('owner','work','family','shared') THEN
+        RAISE EXCEPTION 'realm_override_invalid_target'
+            USING DETAIL = format('p_new_realm = %L', p_new_realm);
+    END IF;
+
+    IF p_table NOT IN ('emails','email_attachments','events','documents',
+                       'vendor_invoice_inbox','vendor_invoice_lines',
+                       'bank_transactions') THEN
+        RAISE EXCEPTION 'realm_override_table_not_allowed'
+            USING DETAIL = format('p_table = %L', p_table);
+    END IF;
+
+    -- Capture old realm for audit. events is partitioned so we need the
+    -- composite key; plain emails/inbox use id.
+    EXECUTE format('SELECT realm FROM %I WHERE id = $1 LIMIT 1', p_table)
+        INTO v_old_realm USING p_id;
+
+    IF v_old_realm IS NULL THEN
+        RAISE EXCEPTION 'realm_override_row_not_found'
+            USING DETAIL = format('%I.id = %L', p_table, p_id);
+    END IF;
+
+    IF v_old_realm = p_new_realm THEN
+        RETURN;  -- no-op
+    END IF;
+
+    -- Open the gate, perform the update, slam it shut.
+    PERFORM set_config('app.realm_override_active', '1', true);
+    EXECUTE format('UPDATE %I SET realm = $1 WHERE id = $2', p_table)
+        USING p_new_realm, p_id;
+    PERFORM set_config('app.realm_override_active', '', true);
+
+    v_caller := coalesce(current_setting('app.current_user', true), session_user);
+
+    INSERT INTO audit_log (pipeline, action, record_type, record_id,
+                           ai_parsed, result, realm)
+    VALUES ('realm_override', 'realm_override', p_table, p_id,
+            jsonb_build_object(
+                'old_realm', v_old_realm,
+                'new_realm', p_new_realm,
+                'reason',    p_reason,
+                'actor',     v_caller
+            ),
+            'success', 'owner');
+END $_$;
+
+COMMENT ON FUNCTION home_ai.realm_override(p_table text, p_id bigint, p_new_realm text, p_reason text) IS 'Owner-only chokepoint for mutating a row''s realm. Refuses unless
+app.current_realm = ''owner''. Sets app.realm_override_active = ''1''
+around the UPDATE so BEFORE UPDATE triggers let it through. Inserts
+an audit_log row. See SPEC §2.5 "Misdirected invoice" edge case.';
+
+CREATE FUNCTION home_ai.set_realm(p_realm text) RETURNS text
+    LANGUAGE plpgsql
+    AS $$
+BEGIN
+    IF p_realm IS NULL OR p_realm = '' THEN
+        -- Permitted: transitional unset state.
+        PERFORM set_config('app.current_realm', '', true);
+        RETURN '';
+    END IF;
+
+    IF p_realm NOT IN ('owner','work','family') THEN
+        RAISE EXCEPTION 'home_ai.set_realm: invalid realm %, expected one of (owner, work, family)', p_realm
+            USING ERRCODE = '22023';  -- invalid_parameter_value
+    END IF;
+
+    PERFORM set_config('app.current_realm', p_realm, true);
+    RETURN p_realm;
+END
+$$;
+
+COMMENT ON FUNCTION home_ai.set_realm(p_realm text) IS 'R2 chokepoint: validate and set app.current_realm for the current transaction. Use this instead of raw SET LOCAL so unrecognised values fail fast.';
+
+CREATE FUNCTION home_ai.trg_realm_immutable() RETURNS trigger
+    LANGUAGE plpgsql
+    AS $$
+BEGIN
+    IF NEW.realm IS DISTINCT FROM OLD.realm
+       AND coalesce(current_setting('app.realm_override_active', true), '') <> '1' THEN
+        RAISE EXCEPTION 'realm_immutable_without_override'
+            USING DETAIL = format('%I.id = %L: realm %L -> %L blocked. '
+                                  'Use home_ai.realm_override() as OWNER.',
+                                  TG_TABLE_NAME, NEW.id, OLD.realm, NEW.realm);
+    END IF;
+    RETURN NEW;
+END $$;
+
+CREATE FUNCTION mart.notify_critical_exception() RETURNS trigger
     LANGUAGE plpgsql
     AS $$
-DECLARE
-    rowcount INT := 0;
 BEGIN
-    -- Make sure partitions exist for the window.
-    PERFORM 1;  -- partitions already created by V72b orchestrator extension
+    IF NEW.severity = 'critical' THEN
+        PERFORM pg_notify(
+            'telegram_immediate',
+            json_build_object(
+                'id',        NEW.id,
+                'kind',      NEW.kind,
+                'source',    NEW.source,
+                'site',      NEW.site,
+                'summary',   NEW.summary,
+                'raised_at', NEW.raised_at
+            )::text
+        );
+    END IF;
+    RETURN NEW;
+END;
+$$;
 
+CREATE FUNCTION mart.refresh_cash_variance_day(window_days integer DEFAULT 30) RETURNS integer
+    LANGUAGE plpgsql
+    AS $$
+DECLARE rowcount INT := 0;
+BEGIN
     INSERT INTO mart.cash_variance
         (transaction_date, site, shift_start_utc, shift_end_utc,
          operator_id, operator_name,
@@ -33,9 +151,9 @@
         'work'
       FROM v_cash_variance_day
      WHERE cal_date >= current_date - window_days
+       AND cal_date <= current_date         -- skip future-dated till rows
        AND variance_minor IS NOT NULL
     ON CONFLICT DO NOTHING;
-
     GET DIAGNOSTICS rowcount = ROW_COUNT;
     RETURN rowcount;
 END
@@ -43,27 +161,169 @@
 
 COMMENT ON FUNCTION mart.refresh_cash_variance_day(window_days integer) IS 'V85: idempotent. Pulls v_cash_variance_day into mart.cash_variance with site=_aggregate, operator_id=_aggregate_day until per-site/operator data lands.';
 
+CREATE FUNCTION mart.run_ghost_shift_detect(window_days integer DEFAULT 14) RETURNS integer
+    LANGUAGE plpgsql SECURITY DEFINER
+    AS $$
+DECLARE
+    inserted int := 0;
+BEGIN
+    PERFORM set_config('app.current_entity', 'all', false);
+    PERFORM home_ai.set_realm('work');
+
+    WITH new_rows AS (
+        INSERT INTO mart.exceptions
+            (severity, kind, source, site, transaction_date,
+             summary, detail, status, realm)
+        SELECT 'medium',
+               'ghost_shift_day',
+               'workforce+touchoffice',
+               g.site,
+               g.report_date,
+               format('Site %s sold £%s on %s but workforce_shifts has 0 rows '
+                      '(within Tanda sync horizon)',
+                      g.site, round(g.plu_value, 2), g.report_date),
+               jsonb_build_object('plu_units', g.plu_units,
+                                  'plu_value', g.plu_value,
+                                  'shift_count', g.shift_count),
+               'open',
+               'work'
+          FROM mart.v_ghost_shifts g
+         WHERE g.report_date >= current_date - window_days
+           AND NOT EXISTS (
+               SELECT 1 FROM mart.exceptions e
+                WHERE e.kind = 'ghost_shift_day'
+                  AND e.site = g.site
+                  AND e.transaction_date = g.report_date
+           )
+        RETURNING 1
+    )
+    SELECT count(*) INTO inserted FROM new_rows;
+    RETURN inserted;
+END;
+$$;
+
+CREATE FUNCTION mart.run_missing_data_hunters() RETURNS TABLE(kind text, raised integer)
+    LANGUAGE plpgsql SECURITY DEFINER
+    AS $$
+DECLARE
+    latest_to       timestamptz;
+    latest_dojo     date;
+    n_to_gap        int := 0;
+    n_dojo_gap      int := 0;
+    n_till_missing  int := 0;
+BEGIN
+    PERFORM set_config('app.current_entity', 'all', false);
+    PERFORM home_ai.set_realm('work');
+
+    -- 1. TouchOffice scrape gap: latest scrape > 26h ago.
+    SELECT max(scraped_at) INTO latest_to FROM touchoffice_scrapes;
+    IF latest_to IS NULL OR latest_to < now() - interval '26 hours' THEN
+        INSERT INTO mart.exceptions
+            (severity, kind, source, transaction_date, summary, detail, status, realm)
+        SELECT 'high', 'to_scrape_gap', 'touchoffice', current_date,
+               format('No TouchOffice scrape in %s — last was %s',
+                      CASE WHEN latest_to IS NULL THEN 'history'
+                           ELSE (age(now(), latest_to))::text END,
+                      COALESCE(latest_to::text, 'never')),
+               jsonb_build_object('latest_scrape_at', latest_to),
+               'open', 'work'
+        WHERE NOT EXISTS (
+            SELECT 1 FROM mart.exceptions
+             WHERE kind='to_scrape_gap' AND status='open'
+               AND raised_at > now() - interval '12 hours'
+        );
+        GET DIAGNOSTICS n_to_gap = ROW_COUNT;
+    END IF;
+
+    -- 2. Dojo settlement gap: latest settlement > yesterday.
+    SELECT max(transaction_date) INTO latest_dojo
+      FROM staging.payments WHERE source = 'dojo';
+    IF latest_dojo IS NULL OR latest_dojo < current_date - 1 THEN
+        INSERT INTO mart.exceptions
+            (severity, kind, source, transaction_date, summary, detail, status, realm)
+        SELECT 'high', 'dojo_settlement_gap', 'dojo', current_date,
+               format('Dojo settlement gap — last transaction_date %s',
+                      COALESCE(latest_dojo::text, 'never')),
+               jsonb_build_object('latest_settlement_date', latest_dojo),
+               'open', 'work'
+        WHERE NOT EXISTS (
+            SELECT 1 FROM mart.exceptions
+             WHERE kind='dojo_settlement_gap' AND status='open'
+               AND raised_at > now() - interval '12 hours'
+        );
+        GET DIAGNOSTICS n_dojo_gap = ROW_COUNT;
+    END IF;
+
+    -- 3. Missing till_reconciliation for yesterday per site that traded.
+    -- A site "traded" if it has a touchoffice_plu_sales row for yesterday.
+    -- Open one exception per missing site/date pair, idempotent.
+    INSERT INTO mart.exceptions
+        (severity, kind, source, site, transaction_date, summary, detail, status, realm)
+    SELECT 'medium',
+           'till_recon_missing',
+           'till+touchoffice',
+           tps.site,
+           current_date - 1,
+           format('No till_reconciliation row for site=%s date=%s — manager '
+                  'should record cashing-up via /m',
+                  tps.site, current_date - 1),
+           jsonb_build_object('plu_units', sum(tps.quantity),
+                              'plu_value', sum(tps.value)),
+           'open',
+           'work'
+      FROM touchoffice_plu_sales tps
+     WHERE tps.report_date = current_date - 1
+     GROUP BY tps.site
+    HAVING NOT EXISTS (
+         SELECT 1 FROM till_reconciliation tr
+          WHERE tr.recon_date = current_date - 1 AND tr.site = tps.site
+       )
+       AND NOT EXISTS (
+         SELECT 1 FROM mart.exceptions e
+          WHERE e.kind='till_recon_missing' AND e.site = tps.site
+            AND e.transaction_date = current_date - 1
+       );
+    GET DIAGNOSTICS n_till_missing = ROW_COUNT;
+
+    RETURN QUERY VALUES
+        ('to_scrape_gap',       n_to_gap),
+        ('dojo_settlement_gap', n_dojo_gap),
+        ('till_recon_missing',  n_till_missing);
+END;
+$$;
+
 CREATE FUNCTION public.claim_event_batch() RETURNS TABLE(id bigint, event_type text, source text, entity_id integer, payload jsonb, trace_id uuid, parent_event_id bigint, idempotency_key text, pipeline_version text, created_at timestamp with time zone)
     LANGUAGE plpgsql SECURITY DEFINER
     SET search_path TO 'public', 'pg_temp'
     AS $$
+DECLARE
+  claimed_ids BIGINT[];
