-- =============================================================================
-- V85 — mart.cash_variance day aggregate + operator-surveillance view skeletons
-- =============================================================================
-- mart.cash_variance was schema-only after V72 (Phase 9 deferred). This
-- migration adds:
--
--   v_cash_variance_day        — derived day-level rows (no site dim — till_
--                                reconciliation doesn't carry site). Compares
--                                aggregate TouchOffice cash totaliser vs
--                                till_reconciliation.cash_counted day-by-day.
--                                Real signal today.
--
--   v_op_persistent_unders     — operator with ≥3 cash-short shifts in last 4
--   v_op_refund_clusters       — refund/void count in last 15min of shift
--                                > 3× operator's per-quarter-hour median
--   v_op_open_tabs_eod         — close-of-day open-tab count by site
--   v_op_refund_spikes_weekly  — weekly refund count > 2σ above operator's
--                                12-week rolling mean
--   v_op_late_night_skew       — variance share post-23:00 > 70% while
--                                pre-23:00 share ≤ 30%
--   v_op_comp_drift            — operator's comp ratio rising 3 weeks in a
--                                row AND latest > 1.5× site median
--
-- All six op-surveillance views are SHAPED but read from raw.touchoffice_orders
-- which is empty today (per-ticket TouchOffice deferred). They'll start
-- returning rows automatically when ticket-level data lands.
--
-- One INSERT helper: refresh_cash_variance_day(window_days) writes
-- mart.cash_variance day rows for the window. Called by the orchestrator.
-- =============================================================================

BEGIN;

-- ── v_cash_variance_day — real signal today ─────────────────────────
CREATE OR REPLACE VIEW v_cash_variance_day AS
WITH pos AS (
  -- Aggregate POS cash totaliser across both sites (no site dim available
  -- on till_reconciliation; we have to collapse).
  SELECT report_date AS cal_date,
         ROUND(SUM(value)::numeric * 100)::bigint AS pos_cash_minor
    FROM public.touchoffice_fixed_totals
   WHERE totaliser_id = 4   -- CASH in Drawer
   GROUP BY 1
),
till AS (
  SELECT recon_date AS cal_date,
         ROUND(SUM(cash_counted) * 100)::bigint AS declared_minor,
         BOOL_OR(status = 'flagged')             AS any_flagged
    FROM public.till_reconciliation
   GROUP BY 1
)
SELECT
  COALESCE(p.cal_date, t.cal_date)                          AS cal_date,
  p.pos_cash_minor,
  t.declared_minor,
  COALESCE(t.declared_minor, 0) - COALESCE(p.pos_cash_minor, 0) AS variance_minor,
  t.any_flagged
  FROM pos p
  FULL OUTER JOIN till t ON t.cal_date = p.cal_date
 WHERE COALESCE(p.cal_date, t.cal_date) >= current_date - INTERVAL '180 days';

COMMENT ON VIEW v_cash_variance_day IS
    'V85: day-level cash variance (pos vs till) without site dim. The proper '
    'per-shift per-operator surveillance lives in v_op_* views below — '
    'inert today; activates when per-ticket TouchOffice data lands.';

-- ── Operator surveillance — six views, shaped per SPEC §4b.6 ───────
-- All read raw.touchoffice_orders + mart.cash_variance. Empty today.

CREATE OR REPLACE VIEW v_op_persistent_unders AS
WITH shifts AS (
  SELECT operator_id, operator_name, transaction_date AS shift_date, site,
         SUM(voids_minor)   AS voids,
         SUM(refunds_minor) AS refunds
    FROM raw.touchoffice_orders
   WHERE transaction_date >= current_date - INTERVAL '30 days'
   GROUP BY 1, 2, 3, 4
),
shorts AS (
  SELECT cv.transaction_date AS short_date, cv.variance_minor
    FROM mart.cash_variance cv
   WHERE cv.transaction_date >= current_date - INTERVAL '30 days'
     AND cv.variance_minor < 0
     AND cv.variance_minor >= -500   -- "small unders" ≤ £5 short
),
op_shorts AS (
  SELECT s.operator_id, s.operator_name, COUNT(*) AS short_shifts
    FROM shifts s
    JOIN shorts sh ON sh.short_date = s.shift_date
   GROUP BY 1, 2
)
SELECT operator_id, operator_name, short_shifts
  FROM op_shorts WHERE short_shifts >= 3;

COMMENT ON VIEW v_op_persistent_unders IS
    'V85: operators with ≥3 small-under (£5 or less) cash-shorts in last 30d. '
    'Active once per-ticket TouchOffice data lands.';

CREATE OR REPLACE VIEW v_op_refund_clusters AS
WITH per_quarter AS (
  SELECT operator_id, operator_name, transaction_date,
         date_trunc('hour', closed_at_utc) +
            INTERVAL '15 min' * (EXTRACT(MINUTE FROM closed_at_utc)::int / 15) AS qtr_start,
         COUNT(*) FILTER (WHERE refunds_minor > 0 OR voids_minor > 0) AS rv_count
    FROM raw.touchoffice_orders
   WHERE transaction_date >= current_date - INTERVAL '14 days'
   GROUP BY 1, 2, 3, 4
),
op_median AS (
  SELECT operator_id,
         PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rv_count) AS median_per_qtr
    FROM per_quarter GROUP BY 1
),
shift_end AS (
  SELECT operator_id, operator_name, transaction_date,
         MAX(closed_at_utc) AS shift_end_utc
    FROM raw.touchoffice_orders
   WHERE transaction_date >= current_date - INTERVAL '14 days'
   GROUP BY 1, 2, 3
)
SELECT pq.operator_id, pq.operator_name, pq.transaction_date,
       pq.rv_count, om.median_per_qtr
  FROM per_quarter pq
  JOIN op_median om ON om.operator_id = pq.operator_id
  JOIN shift_end  se ON se.operator_id = pq.operator_id
                      AND se.transaction_date = pq.transaction_date
 WHERE pq.qtr_start >= se.shift_end_utc - INTERVAL '15 minutes'
   AND pq.rv_count > 3 * om.median_per_qtr
   AND om.median_per_qtr > 0;

CREATE OR REPLACE VIEW v_op_open_tabs_eod AS
SELECT transaction_date, site, COUNT(*) AS open_tab_count,
       SUM(total_gross_minor) AS open_tab_value_minor
  FROM raw.touchoffice_orders
 WHERE transaction_date >= current_date - INTERVAL '14 days'
   AND tender_breakdown ? 'open_tab'
   AND (tender_breakdown->>'open_tab')::numeric > 0
 GROUP BY 1, 2;

CREATE OR REPLACE VIEW v_op_refund_spikes_weekly AS
WITH weekly AS (
  SELECT operator_id, operator_name,
         date_trunc('week', transaction_date)::date AS week,
         COUNT(*) FILTER (WHERE refunds_minor > 0) AS refund_count
    FROM raw.touchoffice_orders
   WHERE transaction_date >= current_date - INTERVAL '84 days'
   GROUP BY 1, 2, 3
),
rolling AS (
  SELECT *,
         AVG(refund_count)   OVER w AS mean_12w,
         STDDEV(refund_count) OVER w AS sd_12w
    FROM weekly
   WINDOW w AS (PARTITION BY operator_id ORDER BY week
                  ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING)
)
SELECT operator_id, operator_name, week, refund_count, mean_12w, sd_12w,
       CASE WHEN sd_12w > 0
            THEN (refund_count - mean_12w) / sd_12w
            ELSE NULL END AS z_score
  FROM rolling
 WHERE sd_12w > 0
   AND refund_count > mean_12w + 2 * sd_12w
   AND week = date_trunc('week', current_date)::date;

CREATE OR REPLACE VIEW v_op_late_night_skew AS
WITH per_shift AS (
  SELECT operator_id, operator_name, transaction_date,
         SUM(ABS(refunds_minor + voids_minor))
            FILTER (WHERE closed_at_utc::time >= '23:00')      AS late_var,
         SUM(ABS(refunds_minor + voids_minor))
            FILTER (WHERE closed_at_utc::time <  '23:00')      AS early_var,
         SUM(ABS(refunds_minor + voids_minor))                 AS total_var
    FROM raw.touchoffice_orders
   WHERE transaction_date >= current_date - INTERVAL '14 days'
   GROUP BY 1, 2, 3
)
SELECT operator_id, operator_name, transaction_date,
       (late_var::numeric  / NULLIF(total_var, 0))::numeric(4,3) AS late_share,
       (early_var::numeric / NULLIF(total_var, 0))::numeric(4,3) AS early_share
  FROM per_shift
 WHERE total_var > 0
   AND late_var::numeric  / NULLIF(total_var, 0) > 0.70
   AND early_var::numeric / NULLIF(total_var, 0) <= 0.30;

CREATE OR REPLACE VIEW v_op_comp_drift AS
WITH weekly AS (
  SELECT operator_id, operator_name, site,
         date_trunc('week', transaction_date)::date AS week,
         SUM(comps_minor)::numeric / NULLIF(SUM(total_gross_minor), 0) AS comp_ratio
    FROM raw.touchoffice_orders
   WHERE transaction_date >= current_date - INTERVAL '21 days'
   GROUP BY 1, 2, 3, 4
),
trends AS (
  SELECT *,
         LAG(comp_ratio, 1) OVER (PARTITION BY operator_id ORDER BY week) AS prev1,
         LAG(comp_ratio, 2) OVER (PARTITION BY operator_id ORDER BY week) AS prev2
    FROM weekly
),
site_median AS (
  SELECT site, week, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY comp_ratio) AS site_median
    FROM weekly GROUP BY 1, 2
)
SELECT t.operator_id, t.operator_name, t.site, t.week, t.comp_ratio,
       sm.site_median
  FROM trends t
  JOIN site_median sm ON sm.site = t.site AND sm.week = t.week
 WHERE t.prev1 IS NOT NULL AND t.prev2 IS NOT NULL
   AND t.comp_ratio > t.prev1 AND t.prev1 > t.prev2
   AND t.comp_ratio > 1.5 * sm.site_median
   AND t.week = date_trunc('week', current_date)::date;

-- ── Helper: refresh mart.cash_variance day-level rows ──────────────
-- Stores aggregate variance per day (cross-site) until per-site till data
-- arrives. operator_id='_aggregate_day' is a sentinel until shift-level
-- data is available.
CREATE OR REPLACE FUNCTION mart.refresh_cash_variance_day(window_days INT DEFAULT 30)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    rowcount INT := 0;
BEGIN
    -- Make sure partitions exist for the window.
    PERFORM 1;  -- partitions already created by V72b orchestrator extension

    INSERT INTO mart.cash_variance
        (transaction_date, site, shift_start_utc, shift_end_utc,
         operator_id, operator_name,
         cash_expected_minor, cash_declared_minor, variance_minor, realm)
    SELECT
        cal_date,
        '_aggregate'::text,
        cal_date::timestamptz,
        (cal_date + INTERVAL '1 day')::timestamptz,
        '_aggregate_day',
        NULL,
        COALESCE(pos_cash_minor, 0),
        COALESCE(declared_minor, 0),
        variance_minor,
        'work'
      FROM v_cash_variance_day
     WHERE cal_date >= current_date - window_days
       AND variance_minor IS NOT NULL
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS rowcount = ROW_COUNT;
    RETURN rowcount;
END
$$;

COMMENT ON FUNCTION mart.refresh_cash_variance_day(INT) IS
    'V85: idempotent. Pulls v_cash_variance_day into mart.cash_variance with '
    'site=_aggregate, operator_id=_aggregate_day until per-site/operator data '
    'lands.';

COMMIT;
