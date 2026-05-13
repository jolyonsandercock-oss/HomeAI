-- ============================================================
-- U34 — Trust restoration: telegram outbox log + revenue fix
-- ============================================================
-- 1. telegram_outbox: log every Telegram send for noise audit.
-- 2. v_daily_unit_economics: replace double-counting accom_revenue
--    (which used revenue_in_house = outstanding balance across all in-house
--     guests) with rate_per_night summed across rooms occupied that night.
-- 3. v_kpi_anomalies recomputes against the new accom_revenue source.
-- ============================================================

-- ── 1. telegram_outbox ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS telegram_outbox (
  id          BIGSERIAL PRIMARY KEY,
  sent_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  source      TEXT NOT NULL,                        -- script/service emitting
  severity    TEXT NOT NULL DEFAULT 'info'
              CHECK (severity IN ('info','warn','critical')),
  chat_id     TEXT,
  http_status INT,
  body_hash   TEXT,                                  -- sha256 of body for dedupe
  body_preview TEXT,                                 -- first 200 chars (no PII)
  suppressed  BOOLEAN NOT NULL DEFAULT false,        -- true = rate-limited, not sent
  suppression_reason TEXT
);

CREATE INDEX IF NOT EXISTS idx_tg_outbox_source_sent ON telegram_outbox (source, sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_tg_outbox_sent        ON telegram_outbox (sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_tg_outbox_severity    ON telegram_outbox (severity, sent_at DESC);

GRANT SELECT, INSERT, UPDATE ON telegram_outbox TO homeai_pipeline;
GRANT USAGE, SELECT ON SEQUENCE telegram_outbox_id_seq TO homeai_pipeline;
GRANT SELECT ON telegram_outbox TO homeai_readonly;
GRANT SELECT ON telegram_outbox TO metabase_app;

-- ── 2. v_daily_accom_revenue ─────────────────────────────────
-- Correct daily accom revenue derivation. Uses caterbook_room_nights which
-- already explodes each booking into one row per night with rate_per_night
-- (= total_amount / nights_in_stay).
--
-- accom_revenue: gross rate-per-night × rooms in-house that night.
-- accom_rooms_occupied: count of distinct rooms in-house.
-- Restricted to <= CURRENT_DATE so we don't generate empty future rows.
-- Zero-rate bookings (Agoda/prepaid) still count as occupancy but contribute
-- £0 — that's a known limitation; per-room-type list price could replace
-- this in a future sprint.
-- Drop dependents first, then this view.
DROP VIEW IF EXISTS v_kpi_anomalies;
DROP VIEW IF EXISTS v_live_ops_kpis;
DROP VIEW IF EXISTS v_daily_unit_economics;
DROP VIEW IF EXISTS v_daily_accom_revenue;
CREATE VIEW v_daily_accom_revenue AS
SELECT
  night_date AS report_date,
  COUNT(*)                              AS rooms_occupied,
  SUM(rate_per_night)::numeric(12,2)    AS accom_revenue,
  COUNT(*) FILTER (WHERE rate_per_night > 0) AS rooms_paid,
  SUM(rate_per_night) FILTER (WHERE rate_per_night > 0)::numeric(12,2) AS accom_revenue_paid
FROM caterbook_room_nights
WHERE night_date <= CURRENT_DATE
GROUP BY night_date;

GRANT SELECT ON v_daily_accom_revenue TO homeai_pipeline;
GRANT SELECT ON v_daily_accom_revenue TO homeai_readonly;
GRANT SELECT ON v_daily_accom_revenue TO metabase_app;

-- ── 3. Rewrite v_daily_unit_economics with correct accom source ─
-- Preserves all existing columns. Only the `accom_revenue` source changes
-- (from caterbook_daily_snapshots.revenue_in_house to v_daily_accom_revenue).
-- Adds `accom_rooms_occupied` for visibility into the derivation.
--
-- (Dropped above before v_daily_accom_revenue.)
CREATE VIEW v_daily_unit_economics AS
WITH to_pub AS (
  SELECT x.report_date,
         (SELECT f.value    FROM touchoffice_fixed_totals f
           WHERE f.site='malthouse' AND f.report_date=x.d AND f.label='NET sales')   AS net_sales,
         (SELECT f.value    FROM touchoffice_fixed_totals f
           WHERE f.site='malthouse' AND f.report_date=x.d AND f.label='GROSS Sales') AS gross_sales,
         (SELECT f.quantity FROM touchoffice_fixed_totals f
           WHERE f.site='malthouse' AND f.report_date=x.d AND f.label='Covers')      AS covers
    FROM (SELECT DISTINCT report_date AS d, report_date FROM touchoffice_fixed_totals) x
), to_sand AS (
  SELECT x.report_date,
         (SELECT f.value    FROM touchoffice_fixed_totals f
           WHERE f.site='sandwich' AND f.report_date=x.d AND f.label='NET sales')   AS net_sales,
         (SELECT f.value    FROM touchoffice_fixed_totals f
           WHERE f.site='sandwich' AND f.report_date=x.d AND f.label='GROSS Sales') AS gross_sales,
         (SELECT f.quantity FROM touchoffice_fixed_totals f
           WHERE f.site='sandwich' AND f.report_date=x.d AND f.label='Covers')      AS covers
    FROM (SELECT DISTINCT report_date AS d, report_date FROM touchoffice_fixed_totals WHERE site='sandwich') x
), cb AS (
  -- Use the new derivation. `in_house_count` stays from snapshots — it's the
  -- guest count, not the revenue.
  SELECT a.report_date,
         a.accom_revenue,
         s.in_house_count,
         a.rooms_occupied AS accom_rooms_occupied
    FROM v_daily_accom_revenue a
    LEFT JOIN caterbook_daily_snapshots s ON s.report_date = a.report_date
), wf AS (
  SELECT s_1.shift_date AS report_date,
         sum(s_1.hours_worked)::numeric(10,2) AS labour_hours,
         sum(s_1.hours_worked * (m.hourly_rate_pence::numeric / 100.0) * (1::numeric + COALESCE(m.on_cost_pct, 12.5) / 100.0))::numeric(12,2) AS labour_cost_est,
         count(DISTINCT s_1.user_external_id) AS staff_on_shift
    FROM workforce_shifts s_1
    LEFT JOIN staff_meta m ON m.user_external_id = s_1.user_external_id
   WHERE s_1.hours_worked IS NOT NULL AND s_1.hours_worked > 0::numeric
   GROUP BY s_1.shift_date
), all_dates AS (
  SELECT report_date FROM to_pub
  UNION SELECT report_date FROM to_sand
  UNION SELECT report_date FROM cb
  UNION SELECT report_date FROM wf
)
SELECT
  d.report_date,
  p.net_sales   AS pub_net_sales,
  p.gross_sales AS pub_gross_sales,
  p.covers      AS pub_covers,
  s.net_sales   AS sandwich_net_sales,
  s.gross_sales AS sandwich_gross_sales,
  s.covers      AS sandwich_covers,
  COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric) AS total_net_sales,
  COALESCE(p.gross_sales, 0::numeric) + COALESCE(s.gross_sales, 0::numeric) AS total_gross_sales,
  COALESCE(p.covers, 0::numeric) + COALESCE(s.covers, 0::numeric) AS total_covers,
  c.accom_revenue,
  c.accom_rooms_occupied,
  c.in_house_count,
  (COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric) + COALESCE(c.accom_revenue, 0::numeric))::numeric(12,2) AS total_revenue,
  w.labour_hours,
  w.labour_cost_est,
  w.staff_on_shift,
  CASE
    WHEN (COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric) + COALESCE(c.accom_revenue, 0::numeric)) > 0::numeric
    THEN round(w.labour_cost_est / NULLIF(COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric) + COALESCE(c.accom_revenue, 0::numeric), 0::numeric) * 100::numeric, 2)
    ELSE NULL
  END AS labour_pct,
  CASE
    WHEN w.labour_hours IS NOT NULL AND w.labour_hours > 0::numeric
    THEN round((COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric) + COALESCE(c.accom_revenue, 0::numeric)) / w.labour_hours, 2)
    ELSE NULL
  END AS splh
FROM all_dates d
LEFT JOIN to_pub  p ON p.report_date = d.report_date
LEFT JOIN to_sand s ON s.report_date = d.report_date
LEFT JOIN cb      c ON c.report_date = d.report_date
LEFT JOIN wf      w ON w.report_date = d.report_date;

GRANT SELECT ON v_daily_unit_economics TO homeai_pipeline;
GRANT SELECT ON v_daily_unit_economics TO homeai_readonly;
GRANT SELECT ON v_daily_unit_economics TO metabase_app;

COMMENT ON VIEW v_daily_unit_economics IS
  'Daily unit economics. accom_revenue derived from v_daily_accom_revenue (sum of rate_per_night across rooms in-house that night) — fixed in U34 after revenue_in_house double-counting.';

-- ── 4. Rebuild v_live_ops_kpis (from V39, depends on v_daily_unit_economics) ──
CREATE VIEW v_live_ops_kpis AS
WITH today_snap AS (
  SELECT
    report_date,
    in_house_count,
    (
      SELECT COUNT(DISTINCT room)
      FROM (
        SELECT (jsonb_array_elements(arrivals) ->> 'room')  AS room
        UNION ALL
        SELECT (jsonb_array_elements(stayovers) ->> 'room') AS room
      ) r
      WHERE room IS NOT NULL
    ) AS occupied_rooms
  FROM caterbook_daily_snapshots
  ORDER BY report_date DESC
  LIMIT 1
),
total_rooms AS (
  SELECT value_num::int AS n FROM ops_constants WHERE key = 'inn_total_rooms'
)
SELECT
  d.report_date,
  d.total_net_sales,
  d.total_revenue,
  d.total_covers,
  d.in_house_count,
  d.labour_hours,
  d.labour_cost_est,
  d.labour_pct,
  d.splh,
  CASE
    WHEN d.labour_pct IS NULL THEN 'unknown'
    WHEN d.labour_pct < (SELECT green_max FROM ops_thresholds WHERE metric='labour_pct') THEN 'green'
    WHEN d.labour_pct <= (SELECT amber_max FROM ops_thresholds WHERE metric='labour_pct') THEN 'amber'
    ELSE 'red'
  END AS labour_pct_light,
  (SELECT total_net_sales  FROM v_daily_unit_economics WHERE report_date = d.report_date - 7) AS net_sales_lw,
  (SELECT labour_cost_est  FROM v_daily_unit_economics WHERE report_date = d.report_date - 7) AS labour_cost_lw,
  COALESCE((SELECT occupied_rooms FROM today_snap WHERE report_date = d.report_date), 0) AS occupied_rooms,
  (SELECT n FROM total_rooms) AS total_rooms,
  CASE
    WHEN (SELECT n FROM total_rooms) IS NULL OR (SELECT n FROM total_rooms) = 0 THEN NULL
    ELSE ROUND(
      100.0 * COALESCE((SELECT occupied_rooms FROM today_snap WHERE report_date = d.report_date), 0)::numeric
            / (SELECT n FROM total_rooms),
      1
    )
  END AS occupancy_pct
FROM v_daily_unit_economics d
ORDER BY d.report_date DESC
LIMIT 1;

GRANT SELECT ON v_live_ops_kpis TO homeai_pipeline;
GRANT SELECT ON v_live_ops_kpis TO homeai_readonly;
GRANT SELECT ON v_live_ops_kpis TO metabase_app;

-- ── 5. Rebuild v_kpi_anomalies (from V39, depends on v_daily_unit_economics) ──
CREATE VIEW v_kpi_anomalies AS
WITH metrics AS (
  SELECT 'pub_net_sales'  AS metric, report_date, pub_net_sales::numeric  AS value FROM v_daily_unit_economics
  UNION ALL SELECT 'accom_revenue',   report_date, accom_revenue::numeric          FROM v_daily_unit_economics
  UNION ALL SELECT 'labour_hours',    report_date, labour_hours::numeric           FROM v_daily_unit_economics
  UNION ALL SELECT 'total_covers',    report_date, total_covers::numeric           FROM v_daily_unit_economics
  UNION ALL SELECT 'in_house_count',  report_date, in_house_count::numeric         FROM v_daily_unit_economics
),
today AS (
  SELECT metric, value AS today_value, report_date AS as_of
  FROM metrics
  WHERE report_date = (SELECT MAX(report_date) FROM v_daily_unit_economics)
),
baseline AS (
  SELECT m.metric, AVG(m.value) AS avg_7d, STDDEV(m.value) AS stddev_7d, COUNT(*) AS sample_n
  FROM metrics m, today t
  WHERE m.metric = t.metric
    AND m.report_date <  t.as_of
    AND m.report_date >= t.as_of - 7
  GROUP BY m.metric
)
SELECT
  t.metric,
  t.as_of AS report_date,
  t.today_value,
  b.avg_7d    AS rolling_avg_7d,
  b.stddev_7d AS rolling_stddev_7d,
  b.sample_n,
  CASE WHEN b.avg_7d IS NULL OR b.avg_7d = 0 THEN NULL
       ELSE ROUND(100.0 * (t.today_value - b.avg_7d) / b.avg_7d, 1)
  END AS delta_pct,
  CASE WHEN b.avg_7d IS NULL OR b.avg_7d = 0 THEN false
       WHEN ABS((t.today_value - b.avg_7d) / b.avg_7d) > 0.5 THEN true
       ELSE false
  END AS flagged,
  CASE WHEN b.avg_7d IS NULL OR b.avg_7d = 0 THEN 0
       ELSE LEAST(100, GREATEST(0, ROUND(ABS(100.0 * (t.today_value - b.avg_7d) / b.avg_7d) - 50)::int))
  END AS severity
FROM today t
LEFT JOIN baseline b USING (metric)
ORDER BY flagged DESC, severity DESC;

GRANT SELECT ON v_kpi_anomalies TO homeai_pipeline;
GRANT SELECT ON v_kpi_anomalies TO homeai_readonly;
GRANT SELECT ON v_kpi_anomalies TO metabase_app;
