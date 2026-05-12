-- ============================================================
-- U32 — daily_unit_economics view + live_ops_kpis
-- ============================================================
-- The headline question: "did the business make money today?"
--
-- Aggregates whole-org (not per-site) because Caterbook + Workforce are
-- both Malthouse-only and splitting Workforce by department→site is a
-- separate sprint. Pub vs Sandwich Bar split is preserved in the
-- touchoffice columns.
-- ============================================================

CREATE OR REPLACE VIEW v_daily_unit_economics AS
WITH to_pub AS (
  SELECT report_date,
         (SELECT value FROM touchoffice_fixed_totals f
            WHERE f.site='malthouse' AND f.report_date=d AND f.label='NET sales')   AS net_sales,
         (SELECT value FROM touchoffice_fixed_totals f
            WHERE f.site='malthouse' AND f.report_date=d AND f.label='GROSS Sales') AS gross_sales,
         (SELECT quantity FROM touchoffice_fixed_totals f
            WHERE f.site='malthouse' AND f.report_date=d AND f.label='Covers')      AS covers
    FROM (SELECT DISTINCT report_date AS d, report_date FROM touchoffice_fixed_totals) x
),
to_sand AS (
  SELECT report_date,
         (SELECT value FROM touchoffice_fixed_totals f
            WHERE f.site='sandwich' AND f.report_date=d AND f.label='NET sales')    AS net_sales,
         (SELECT value FROM touchoffice_fixed_totals f
            WHERE f.site='sandwich' AND f.report_date=d AND f.label='GROSS Sales')  AS gross_sales,
         (SELECT quantity FROM touchoffice_fixed_totals f
            WHERE f.site='sandwich' AND f.report_date=d AND f.label='Covers')       AS covers
    FROM (SELECT DISTINCT report_date AS d, report_date FROM touchoffice_fixed_totals WHERE site='sandwich') x
),
cb AS (
  SELECT report_date, revenue_in_house AS accom_revenue, in_house_count
    FROM caterbook_daily_snapshots
),
wf AS (
  SELECT s.shift_date AS report_date,
         SUM(s.hours_worked)::numeric(10,2) AS labour_hours,
         SUM(s.hours_worked * (m.hourly_rate_pence::numeric / 100.0)
             * (1 + COALESCE(m.on_cost_pct, 12.5) / 100.0))::numeric(12,2) AS labour_cost_est,
         COUNT(DISTINCT s.user_external_id)  AS staff_on_shift
    FROM workforce_shifts s
    LEFT JOIN staff_meta m ON m.user_external_id = s.user_external_id
   WHERE s.hours_worked IS NOT NULL AND s.hours_worked > 0
   GROUP BY s.shift_date
),
all_dates AS (
  SELECT report_date FROM to_pub
  UNION SELECT report_date FROM to_sand
  UNION SELECT report_date FROM cb
  UNION SELECT report_date FROM wf
)
SELECT
  d.report_date,
  -- Per-site TouchOffice
  p.net_sales            AS pub_net_sales,
  p.gross_sales          AS pub_gross_sales,
  p.covers               AS pub_covers,
  s.net_sales            AS sandwich_net_sales,
  s.gross_sales          AS sandwich_gross_sales,
  s.covers               AS sandwich_covers,
  -- Combined sales
  COALESCE(p.net_sales,0)   + COALESCE(s.net_sales,0)   AS total_net_sales,
  COALESCE(p.gross_sales,0) + COALESCE(s.gross_sales,0) AS total_gross_sales,
  COALESCE(p.covers,0)      + COALESCE(s.covers,0)      AS total_covers,
  -- Accommodation
  c.accom_revenue,
  c.in_house_count,
  -- Total revenue (sales + accom)
  (COALESCE(p.net_sales,0) + COALESCE(s.net_sales,0) + COALESCE(c.accom_revenue,0))::numeric(12,2)
                                                       AS total_revenue,
  -- Labour
  w.labour_hours,
  w.labour_cost_est,
  w.staff_on_shift,
  -- KPIs
  CASE WHEN (COALESCE(p.net_sales,0)+COALESCE(s.net_sales,0)+COALESCE(c.accom_revenue,0)) > 0
       THEN ROUND( (w.labour_cost_est /
                    NULLIF(COALESCE(p.net_sales,0)+COALESCE(s.net_sales,0)+COALESCE(c.accom_revenue,0),0)
                   * 100)::numeric, 2)
       ELSE NULL END                                    AS labour_pct,
  CASE WHEN w.labour_hours IS NOT NULL AND w.labour_hours > 0
       THEN ROUND(((COALESCE(p.net_sales,0)+COALESCE(s.net_sales,0)+COALESCE(c.accom_revenue,0))
                   / w.labour_hours)::numeric, 2)
       ELSE NULL END                                    AS splh
FROM all_dates d
LEFT JOIN to_pub  p ON p.report_date = d.report_date
LEFT JOIN to_sand s ON s.report_date = d.report_date
LEFT JOIN cb      c ON c.report_date = d.report_date
LEFT JOIN wf      w ON w.report_date = d.report_date;

GRANT SELECT ON v_daily_unit_economics TO homeai_pipeline, homeai_readonly;

-- ── Threshold table — tunable without redeploy ─────────────
CREATE TABLE IF NOT EXISTS ops_thresholds (
  metric          TEXT PRIMARY KEY,
  green_max       NUMERIC,
  amber_max       NUMERIC,
  red_min         NUMERIC,
  note            TEXT,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO ops_thresholds (metric, green_max, amber_max, red_min, note) VALUES
  ('labour_pct',  30.0, 32.0, 32.0, 'Labour % of total revenue. <30 green, 30-32 amber, >32 red'),
  ('splh',         0.0,  0.0,  0.0, 'Sales per labour hour. Not currently traffic-lighted; surfaced as a number.'),
  ('variance_gbp', 5.0, 10.0, 10.0, 'Cashing-up variance £. <£5 green, £5-£10 amber, >£10 red')
ON CONFLICT (metric) DO NOTHING;

GRANT SELECT ON ops_thresholds TO homeai_pipeline, homeai_readonly;

-- ── Live KPIs (single row — yesterday's snapshot + flags) ──
CREATE OR REPLACE VIEW v_live_ops_kpis AS
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
  -- Traffic light derived from the labour_pct threshold table
  CASE
    WHEN d.labour_pct IS NULL THEN 'unknown'
    WHEN d.labour_pct <  (SELECT green_max FROM ops_thresholds WHERE metric='labour_pct') THEN 'green'
    WHEN d.labour_pct <= (SELECT amber_max FROM ops_thresholds WHERE metric='labour_pct') THEN 'amber'
    ELSE 'red'
  END AS labour_pct_light,
  -- Same-day-last-week comparison
  (SELECT total_net_sales FROM v_daily_unit_economics
    WHERE report_date = d.report_date - 7) AS net_sales_lw,
  (SELECT labour_cost_est FROM v_daily_unit_economics
    WHERE report_date = d.report_date - 7) AS labour_cost_lw
FROM v_daily_unit_economics d
ORDER BY d.report_date DESC
LIMIT 1;

GRANT SELECT ON v_live_ops_kpis TO homeai_pipeline, homeai_readonly;
