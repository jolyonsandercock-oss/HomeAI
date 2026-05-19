-- =============================================================================
-- V157 — U135 T6: cash-up reconciliation slugs
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    -- Today's cash-up state per site × till. One row per till plus a totals
    -- row per site. The frontend renders this as a side-by-side cash-up form.
    ('cashup_reconciliation_today',
     'Cash-up reconciliation — target date',
     'Joins Z-reads (TouchOffice) + Dojo cards + Caterpay + Collins + cashup_inputs.cash_taken into a one-row-per-till comparison with variance columns.',
     $sql$WITH d AS (
              SELECT COALESCE(:date::date, CURRENT_DATE) AS day
          ),
          z_reads AS (
              -- Z-reads are stored per site, not per till — split equally across
              -- the configured till list for the site. If a per-till feed lands
              -- later, swap this CTE.
              SELECT site, SUM(value) AS z_total_pence
                FROM touchoffice_department_sales, d
               WHERE report_date = d.day
               GROUP BY site
          ),
          tills AS (
              SELECT 'malthouse' AS site, unnest(ARRAY['till_bar','till_restaurant']) AS till_id
              UNION ALL
              SELECT 'sandwich', unnest(ARRAY['till_cafe'])
          ),
          dojo_by_site AS (
              SELECT CASE mid WHEN '476621462111863' THEN 'malthouse' ELSE 'sandwich' END AS site,
                     SUM(transaction_amount) FILTER (WHERE transaction_type='Sale') * 100 AS card_pence,
                     SUM(gratuity_amount) * 100 AS gratuity_pence
                FROM dojo_transactions, d
               WHERE transaction_date = d.day
               GROUP BY 1
          ),
          collins_by_site AS (
              SELECT 'malthouse'::text AS site,
                     COALESCE(SUM(deposit_pence), 0) AS collins_deposit_pence
                FROM restaurant_reservations, d
               WHERE deposit_paid_at::date = d.day
          )
          SELECT
              t.site,
              t.till_id,
              -- Z-read split: half per till for malthouse (bar/restaurant);
              -- full Z-read for sandwich (one till). Adjust when per-till feed lands.
              CASE WHEN t.site = 'malthouse' THEN COALESCE(z.z_total_pence * 100, 0) / 2
                   ELSE COALESCE(z.z_total_pence * 100, 0) END::int       AS z_read_pence,
              ci.cash_taken_pence,
              -- Cards: pooled per site, allocated to "till_bar" or "till_cafe"
              -- by default (restaurant till is cash-led). Override via cashup_inputs.
              CASE WHEN t.till_id IN ('till_bar','till_cafe') THEN dojo.card_pence::int ELSE 0 END AS card_pence,
              CASE WHEN t.till_id IN ('till_bar','till_cafe') THEN dojo.gratuity_pence::int ELSE 0 END AS gratuity_pence,
              ci.caterpay_pence,
              -- Collins deposits go on restaurant till
              CASE WHEN t.till_id = 'till_restaurant' THEN collins.collins_deposit_pence ELSE 0 END AS collins_deposit_pence,
              ci.manual_notes,
              ci.entered_at,
              -- Variance: cash_taken + card + caterpay + collins  vs  Z-read
              (
                COALESCE(ci.cash_taken_pence, 0)
                + CASE WHEN t.till_id IN ('till_bar','till_cafe') THEN COALESCE(dojo.card_pence::int, 0) ELSE 0 END
                + COALESCE(ci.caterpay_pence, 0)
                + CASE WHEN t.till_id = 'till_restaurant' THEN COALESCE(collins.collins_deposit_pence, 0) ELSE 0 END
              ) - (CASE WHEN t.site = 'malthouse' THEN COALESCE(z.z_total_pence * 100, 0) / 2
                        ELSE COALESCE(z.z_total_pence * 100, 0) END)::int  AS variance_pence
            FROM tills t
            LEFT JOIN z_reads      z       ON z.site = t.site
            LEFT JOIN dojo_by_site dojo    ON dojo.site = t.site
            LEFT JOIN collins_by_site collins ON collins.site = t.site
            LEFT JOIN cashup_inputs ci
                   ON ci.site = t.site
                  AND ci.till_id = t.till_id
                  AND ci.cashup_date = (SELECT day FROM d)
           ORDER BY t.site, t.till_id$sql$,
     '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
     'table', true, 'V157-U135T6', NOW(), 'V157-U135T6',
     'Per U135 T6 plan.', 'work'),

    -- Running safe balance from start of current month
    ('safe_running_balance',
     'Safe running balance — current month',
     'Per-site running safe balance from start of current month. Positive = to-safe; negative = from-safe.',
     $sql$WITH m AS (
              SELECT date_trunc('month', CURRENT_DATE)::date AS month_start
          )
          SELECT s.site,
                 SUM(CASE WHEN s.direction = 'to_safe' THEN s.amount_pence ELSE -s.amount_pence END) AS running_balance_pence,
                 COUNT(*) AS movement_count,
                 max(s.movement_date) AS last_movement
            FROM safe_movements s, m
           WHERE s.movement_date >= m.month_start
           GROUP BY s.site
           ORDER BY s.site$sql$,
     '{}'::jsonb, 'table', true, 'V157-U135T6', NOW(), 'V157-U135T6',
     'Per U135 T6 plan.', 'work'),

    -- Safe movements list for a target date (drives the date-view audit)
    ('safe_movements_for_date',
     'Safe movements on a target date',
     'List of to_safe / from_safe movements for review/audit.',
     $sql$SELECT id, site, direction, amount_pence, notes, entered_by, entered_at
           FROM safe_movements
          WHERE movement_date = COALESCE(:date::date, CURRENT_DATE)
          ORDER BY entered_at$sql$,
     '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
     'table', true, 'V157-U135T6', NOW(), 'V157-U135T6',
     'Per U135 T6 plan.', 'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       param_schema = EXCLUDED.param_schema,
       active       = true,
       approved_at  = NOW();

COMMIT;
