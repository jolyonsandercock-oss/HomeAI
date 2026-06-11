-- =============================================================================
-- V265 — v_daily_unit_economics: head_office revenue basis + V262 labour cost
-- =============================================================================
-- Review findings (2026-06-11, Jo-verified figures):
--   1. total_revenue double-counted accommodation: malthouse "NET sales"
--      already INCLUDES the ACCOM department, then caterbook accom_revenue was
--      added on top (~£30k/May overstatement).
--   2. The per-till scrapes are contaminated (phantom ALCOHOL split, items the
--      head-office report classifies differently): DB sandwich May £37,374 vs
--      true cafe £33,142. Unfixable at per-till grain.
--   3. labour_cost_est used staff_meta CURRENT rate × 12.5% on-cost — both
--      wrong vs the V262 report-anchored costing (award_cost × 1.2692).
--
-- Fix: revenue basis = head_office consolidated department sales (site 0 —
-- single combined DRINK line, includes ACCOM + Cafe; reconciled to the penny
-- vs Jo's report: May-2026 £151,516.82). Legacy per-till fallback (WITHOUT the
-- caterbook add) only for days with no head_office scrape (pre-2026 gaps);
-- exposed via revenue_source so consumers can see the basis. Labour cost now
-- prefers workforce_shifts.cost_estimate (V262 on-costed, era-tunable via
-- u275-set-oncost.sh) with the old formula only as NULL-fallback.
-- labour_pct + splh now divide by total_revenue (matches Workforce's Wage% =
-- cost / Revenue Actual; May ⇒ ~29.3%).
--
-- Column ORDER preserved (6 dependent views); new columns appended at end.
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW v_daily_unit_economics AS
 WITH to_pub AS (
         SELECT x.d AS report_date,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'malthouse' AND f.report_date = x.d AND f.label = 'NET sales') AS net_sales,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'malthouse' AND f.report_date = x.d AND f.label = 'GROSS Sales') AS gross_sales,
            ( SELECT f.quantity FROM touchoffice_fixed_totals f
                  WHERE f.site = 'malthouse' AND f.report_date = x.d AND f.label = 'Covers') AS covers
           FROM ( SELECT DISTINCT report_date AS d FROM touchoffice_fixed_totals) x
        ), to_sand AS (
         SELECT x.d AS report_date,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'sandwich' AND f.report_date = x.d AND f.label = 'NET sales') AS net_sales,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'sandwich' AND f.report_date = x.d AND f.label = 'GROSS Sales') AS gross_sales,
            ( SELECT f.quantity FROM touchoffice_fixed_totals f
                  WHERE f.site = 'sandwich' AND f.report_date = x.d AND f.label = 'Covers') AS covers
           FROM ( SELECT DISTINCT report_date AS d FROM touchoffice_fixed_totals
                  WHERE site = 'sandwich') x
        ), ho AS (
         -- Consolidated head-office aggregate: the authoritative revenue.
         SELECT report_date, sum(value)::numeric(12,2) AS revenue
           FROM touchoffice_department_sales
          WHERE site = 'head_office'
          GROUP BY report_date
        ), cb AS (
         SELECT a.report_date,
            a.accom_revenue,
            s_1.in_house_count,
            a.rooms_occupied AS accom_rooms_occupied
           FROM v_daily_accom_revenue a
             LEFT JOIN caterbook_daily_snapshots s_1 ON s_1.report_date = a.report_date
        ), wf AS (
         SELECT s_1.shift_date AS report_date,
            sum(s_1.hours_worked)::numeric(10,2) AS labour_hours,
            -- V262 on-costed cost (award_cost × (1+on_cost%)); legacy formula
            -- only where cost_estimate is missing.
            sum(COALESCE(s_1.cost_estimate,
                         s_1.hours_worked * (m.hourly_rate_pence::numeric / 100.0)
                           * (1::numeric + COALESCE(m.on_cost_pct, 12.5) / 100.0)))::numeric(12,2) AS labour_cost_est,
            count(DISTINCT s_1.user_external_id) AS staff_on_shift
           FROM workforce_shifts s_1
             LEFT JOIN staff_meta m ON m.user_external_id = s_1.user_external_id
          WHERE s_1.hours_worked IS NOT NULL AND s_1.hours_worked > 0::numeric
          GROUP BY s_1.shift_date
        ), wf_site AS (
         SELECT s_1.shift_date AS report_date,
            COALESCE(d_1.site, 'shared') AS site,
            sum(s_1.hours_worked)::numeric(10,2) AS hours,
            sum(COALESCE(s_1.cost_estimate,
                         s_1.hours_worked * (m.hourly_rate_pence::numeric / 100.0)
                           * (1::numeric + COALESCE(m.on_cost_pct, 12.5) / 100.0)))::numeric(12,2) AS cost
           FROM workforce_shifts s_1
             LEFT JOIN staff_meta m ON m.user_external_id = s_1.user_external_id
             LEFT JOIN workforce_departments d_1 ON d_1.external_id = s_1.department_external_id
          WHERE s_1.hours_worked IS NOT NULL AND s_1.hours_worked > 0::numeric
          GROUP BY s_1.shift_date, COALESCE(d_1.site, 'shared')
        ), wf_pivot AS (
         SELECT report_date,
            sum(cost)  FILTER (WHERE site = 'pub')    AS labour_cost_pub,
            sum(cost)  FILTER (WHERE site = 'cafe')   AS labour_cost_cafe,
            sum(cost)  FILTER (WHERE site = 'inn')    AS labour_cost_inn,
            sum(cost)  FILTER (WHERE site = 'shared') AS labour_cost_shared,
            sum(hours) FILTER (WHERE site = 'pub')    AS labour_hours_pub,
            sum(hours) FILTER (WHERE site = 'cafe')   AS labour_hours_cafe,
            sum(hours) FILTER (WHERE site = 'inn')    AS labour_hours_inn,
            sum(hours) FILTER (WHERE site = 'shared') AS labour_hours_shared
           FROM wf_site
          GROUP BY report_date
        ), all_dates AS (
         SELECT report_date FROM to_pub
         UNION SELECT report_date FROM to_sand
         UNION SELECT report_date FROM ho
         UNION SELECT report_date FROM cb
         UNION SELECT report_date FROM wf
        )
 SELECT d.report_date,
    p.net_sales AS pub_net_sales,
    p.gross_sales AS pub_gross_sales,
    p.covers AS pub_covers,
    s.net_sales AS sandwich_net_sales,
    s.gross_sales AS sandwich_gross_sales,
    s.covers AS sandwich_covers,
    COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric) AS total_net_sales,
    COALESCE(p.gross_sales, 0::numeric) + COALESCE(s.gross_sales, 0::numeric) AS total_gross_sales,
    COALESCE(p.covers, 0::numeric) + COALESCE(s.covers, 0::numeric) AS total_covers,
    cb.accom_revenue,
    cb.accom_rooms_occupied,
    cb.in_house_count,
    -- Authoritative: head_office consolidated. Legacy fallback = per-till sum
    -- WITHOUT caterbook accom (the old +accom double-counted: malthouse NET
    -- already includes the ACCOM department).
    COALESCE(ho.revenue,
             (COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric)))::numeric(12,2) AS total_revenue,
    wf.labour_hours,
    wf.labour_cost_est,
    wf.staff_on_shift,
        CASE
            WHEN COALESCE(ho.revenue, COALESCE(p.net_sales,0::numeric)+COALESCE(s.net_sales,0::numeric)) > 0::numeric
            THEN round(wf.labour_cost_est
                       / COALESCE(ho.revenue, COALESCE(p.net_sales,0::numeric)+COALESCE(s.net_sales,0::numeric))
                       * 100::numeric, 1)
            ELSE NULL::numeric
        END AS labour_pct,
        CASE
            WHEN wf.labour_hours > 0::numeric
            THEN round(COALESCE(ho.revenue, COALESCE(p.net_sales,0::numeric)+COALESCE(s.net_sales,0::numeric))
                       / wf.labour_hours, 2)
            ELSE NULL::numeric
        END AS splh,
    wp.labour_cost_pub,
    wp.labour_cost_cafe,
    wp.labour_cost_inn,
    wp.labour_cost_shared,
    wp.labour_hours_pub,
    wp.labour_hours_cafe,
    wp.labour_hours_inn,
    wp.labour_hours_shared,
        CASE
            WHEN COALESCE(p.net_sales, 0::numeric) > 0::numeric AND wp.labour_cost_pub IS NOT NULL
            THEN round(wp.labour_cost_pub / p.net_sales * 100::numeric, 1)
            ELSE NULL::numeric
        END AS pub_labour_pct,
        CASE
            WHEN COALESCE(s.net_sales, 0::numeric) > 0::numeric AND wp.labour_cost_cafe IS NOT NULL
            THEN round(wp.labour_cost_cafe / s.net_sales * 100::numeric, 1)
            ELSE NULL::numeric
        END AS cafe_labour_pct,
    -- appended columns (CREATE OR REPLACE allows adding at the end only)
    CASE WHEN ho.revenue IS NOT NULL THEN 'head_office' ELSE 'per_till_legacy' END AS revenue_source,
    ho.revenue AS head_office_revenue
   FROM all_dates d
     LEFT JOIN to_pub p ON p.report_date = d.report_date
     LEFT JOIN to_sand s ON s.report_date = d.report_date
     LEFT JOIN ho ON ho.report_date = d.report_date
     LEFT JOIN cb ON cb.report_date = d.report_date
     LEFT JOIN wf ON wf.report_date = d.report_date
     LEFT JOIN wf_pivot wp ON wp.report_date = d.report_date;

COMMENT ON VIEW v_daily_unit_economics IS
  'Daily economics. total_revenue = head_office consolidated TouchOffice aggregate (authoritative; reconciled to Jo''s report May-2026 £151,516.82) with per-till fallback (revenue_source column). labour_cost_est = V262 on-costed (award_cost × 1+on_cost%). labour_pct = cost/total_revenue (matches Workforce Wage%).';

-- ── compute-and-assert: Jo's reference months (head_office dept-sum basis) ──
DO $$
DECLARE v_may numeric; v_apr numeric; v_mar numeric;
BEGIN
  SELECT sum(total_revenue) INTO v_may FROM v_daily_unit_economics
   WHERE report_date BETWEEN '2026-05-01' AND '2026-05-31' AND revenue_source='head_office';
  SELECT sum(total_revenue) INTO v_apr FROM v_daily_unit_economics
   WHERE report_date BETWEEN '2026-04-01' AND '2026-04-30' AND revenue_source='head_office';
  SELECT sum(total_revenue) INTO v_mar FROM v_daily_unit_economics
   WHERE report_date BETWEEN '2026-03-01' AND '2026-03-31' AND revenue_source='head_office';
  IF v_may IS DISTINCT FROM 151516.82 THEN
    RAISE EXCEPTION 'V265 assert: May head_office revenue % <> 151516.82', v_may; END IF;
  IF v_apr IS DISTINCT FROM 103369.54 THEN
    RAISE EXCEPTION 'V265 assert: Apr head_office revenue % <> 103369.54', v_apr; END IF;
  IF v_mar IS DISTINCT FROM 56933.23 THEN
    RAISE EXCEPTION 'V265 assert: Mar head_office revenue % <> 56933.23', v_mar; END IF;
  RAISE NOTICE 'V265: Mar %, Apr %, May % — all match Jo''s report exactly', v_mar, v_apr, v_may;
END $$;

COMMIT;
