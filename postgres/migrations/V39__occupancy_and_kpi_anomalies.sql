-- ============================================================
-- U33 — Live occupancy bridge + KPI anomaly guard
-- ============================================================
-- 1. ops_constants: data-driven config (room count etc.) so dashboard
--    doesn't hard-code numbers that change when we add/remove rooms.
-- 2. v_live_ops_kpis extended with occupied_rooms + occupancy_pct.
-- 3. v_kpi_anomalies: today vs 7-day rolling avg, flag ±50% outliers.
--    Catches silent extraction failures (empty PDF, missed email, etc).
-- ============================================================

-- ── 1. ops_constants ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ops_constants (
  key         TEXT PRIMARY KEY,
  value_num   NUMERIC,
  value_text  TEXT,
  note        TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO ops_constants (key, value_num, note) VALUES
  ('inn_total_rooms', 9, 'Bookable rooms at the inn (Rm1-Rm8 + suite-9). Flat excluded — let lifestyle/long-term.')
ON CONFLICT (key) DO NOTHING;

GRANT SELECT ON ops_constants TO homeai_pipeline;
GRANT SELECT ON ops_constants TO homeai_readonly;
GRANT SELECT ON ops_constants TO metabase_app;

-- ── 2. v_live_ops_kpis: add occupancy ────────────────────────
-- occupied_rooms derives from the latest caterbook_daily_snapshots row by
-- counting distinct rooms across arrivals + stayovers JSON (departures
-- are leaving so don't count toward end-of-day occupancy).
DROP VIEW IF EXISTS v_live_ops_kpis;

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

GRANT SELECT ON v_live_ops_kpis TO homeai_readonly;
GRANT SELECT ON v_live_ops_kpis TO homeai_pipeline;
GRANT SELECT ON v_live_ops_kpis TO metabase_app;

-- ── 3. v_kpi_anomalies ───────────────────────────────────────
-- Compare today's value to 7-day rolling avg (yesterday..today-7).
-- Flag if outside ±50% AND today is "non-trivial" (rolling avg > 0).
-- severity = |delta_pct| - 50, capped at 100. Higher = louder.
CREATE OR REPLACE VIEW v_kpi_anomalies AS
WITH metrics AS (
  SELECT
    'pub_net_sales'    AS metric, report_date, pub_net_sales::numeric    AS value FROM v_daily_unit_economics
  UNION ALL SELECT
    'accom_revenue',           report_date, accom_revenue::numeric            FROM v_daily_unit_economics
  UNION ALL SELECT
    'labour_hours',            report_date, labour_hours::numeric             FROM v_daily_unit_economics
  UNION ALL SELECT
    'total_covers',            report_date, total_covers::numeric             FROM v_daily_unit_economics
  UNION ALL SELECT
    'in_house_count',          report_date, in_house_count::numeric           FROM v_daily_unit_economics
),
today AS (
  SELECT metric, value AS today_value, report_date AS as_of
  FROM metrics
  WHERE report_date = (SELECT MAX(report_date) FROM v_daily_unit_economics)
),
baseline AS (
  SELECT
    m.metric,
    AVG(m.value)    AS avg_7d,
    STDDEV(m.value) AS stddev_7d,
    COUNT(*)        AS sample_n
  FROM metrics m, today t
  WHERE m.metric = t.metric
    AND m.report_date <  t.as_of
    AND m.report_date >= t.as_of - 7
  GROUP BY m.metric
)
SELECT
  t.metric,
  t.as_of                              AS report_date,
  t.today_value,
  b.avg_7d                             AS rolling_avg_7d,
  b.stddev_7d                          AS rolling_stddev_7d,
  b.sample_n,
  CASE
    WHEN b.avg_7d IS NULL OR b.avg_7d = 0 THEN NULL
    ELSE ROUND(100.0 * (t.today_value - b.avg_7d) / b.avg_7d, 1)
  END                                  AS delta_pct,
  CASE
    WHEN b.avg_7d IS NULL OR b.avg_7d = 0 THEN false
    WHEN ABS((t.today_value - b.avg_7d) / b.avg_7d) > 0.5 THEN true
    ELSE false
  END                                  AS flagged,
  CASE
    WHEN b.avg_7d IS NULL OR b.avg_7d = 0 THEN 0
    ELSE LEAST(
      100,
      GREATEST(0, ROUND(ABS(100.0 * (t.today_value - b.avg_7d) / b.avg_7d) - 50)::int)
    )
  END                                  AS severity
FROM today t
LEFT JOIN baseline b USING (metric)
ORDER BY flagged DESC, severity DESC;

GRANT SELECT ON v_kpi_anomalies TO homeai_readonly;
GRANT SELECT ON v_kpi_anomalies TO homeai_pipeline;
GRANT SELECT ON v_kpi_anomalies TO metabase_app;
