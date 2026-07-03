-- V284: v_daily_unit_economics — displayed totals must follow head_office truth,
-- and "no data yet" must read NULL, not 0.
--
-- Two defects found in the 2026-07-03 dashboard data-integrity review:
--
--   1. total_net_sales / total_gross_sales / total_covers were computed ONLY from
--      the per-site rows (malthouse + sandwich), while revenue_source claimed
--      'head_office'. On days where the per-site scrape was contaminated or
--      absent, the displayed totals diverged from the head_office consolidated
--      figure (the penny-verified canonical source per the TouchOffice
--      head_office decision):
--        2026-05-31  shown 9,780.32 vs head_office 5,548.15  (+4,232.17 —
--                    the per-till 'sandwich' row that day holds the consolidated
--                    total and 'malthouse' overlaps it: a double-count)
--        2026-06-16  shown 1,710.74 vs head_office 1,785.64  (-74.90)
--        2026-06-17  shown       0 vs head_office 2,949.60
--        2026-06-18  shown       0 vs head_office 3,448.58
--      Fix: totals now prefer the head_office fixed-totals row and fall back to
--      the per-site sum only when head_office is absent. Per-site COLUMNS
--      (pub_*/sandwich_*) are intentionally left as scraped — they are the only
--      split source; May-31's contaminated split remains visible there and is a
--      separate data-repair decision.
--
--   2. COALESCE(x,0)+COALESCE(y,0) rendered days with NO till data as 0 — so
--      every morning before the nightly scrape, "today" showed £0 / 0 covers,
--      tripping a false covers -100% anomaly (severity 50) at 6am daily and
--      dipping the revenue sparkline to zero. Fix: when neither head_office nor
--      any per-site row exists, totals are NULL. Downstream consumers
--      (anomalies, sparklines, KPI header) already render NULL as
--      "unknown/skip", matching how labour_hours behaves pre-ingest.
--
-- revenue_source now describes the source of total_net_sales (head_office /
-- per_till_legacy / NULL when no data), instead of the source of total_revenue.
--
-- CREATE OR REPLACE (no DROP): v_live_ops_kpis depends on this view; column
-- list, order and types are unchanged.

CREATE OR REPLACE VIEW v_daily_unit_economics AS
 WITH to_pub AS (
         SELECT x.d AS report_date,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'malthouse' AND f.report_date = x.d AND f.label = 'NET sales') AS net_sales,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'malthouse' AND f.report_date = x.d AND f.label = 'GROSS Sales') AS gross_sales,
            ( SELECT f.quantity FROM touchoffice_fixed_totals f
                  WHERE f.site = 'malthouse' AND f.report_date = x.d AND f.label = 'Covers') AS covers
           FROM ( SELECT DISTINCT touchoffice_fixed_totals.report_date AS d
                   FROM touchoffice_fixed_totals) x
        ), to_sand AS (
         SELECT x.d AS report_date,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'sandwich' AND f.report_date = x.d AND f.label = 'NET sales') AS net_sales,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'sandwich' AND f.report_date = x.d AND f.label = 'GROSS Sales') AS gross_sales,
            ( SELECT f.quantity FROM touchoffice_fixed_totals f
                  WHERE f.site = 'sandwich' AND f.report_date = x.d AND f.label = 'Covers') AS covers
           FROM ( SELECT DISTINCT touchoffice_fixed_totals.report_date AS d
                   FROM touchoffice_fixed_totals
                  WHERE touchoffice_fixed_totals.site = 'sandwich') x
        ), ho_fix AS (
         -- head_office consolidated fixed totals: the canonical NET/GROSS/Covers.
         SELECT x.d AS report_date,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'head_office' AND f.report_date = x.d AND f.label = 'NET sales') AS net_sales,
            ( SELECT f.value FROM touchoffice_fixed_totals f
                  WHERE f.site = 'head_office' AND f.report_date = x.d AND f.label = 'GROSS Sales') AS gross_sales,
            ( SELECT f.quantity FROM touchoffice_fixed_totals f
                  WHERE f.site = 'head_office' AND f.report_date = x.d AND f.label = 'Covers') AS covers
           FROM ( SELECT DISTINCT touchoffice_fixed_totals.report_date AS d
                   FROM touchoffice_fixed_totals
                  WHERE touchoffice_fixed_totals.site = 'head_office') x
        ), ho AS (
         SELECT touchoffice_department_sales.report_date,
            sum(touchoffice_department_sales.value)::numeric(12,2) AS revenue
           FROM touchoffice_department_sales
          WHERE touchoffice_department_sales.site = 'head_office'
          GROUP BY touchoffice_department_sales.report_date
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
            sum(COALESCE(s_1.cost_estimate, s_1.hours_worked * (m.hourly_rate_pence::numeric / 100.0) * (1::numeric + COALESCE(m.on_cost_pct, 12.5) / 100.0)))::numeric(12,2) AS labour_cost_est,
            count(DISTINCT s_1.user_external_id) AS staff_on_shift
           FROM workforce_shifts s_1
             LEFT JOIN staff_meta m ON m.user_external_id = s_1.user_external_id
          WHERE s_1.hours_worked IS NOT NULL AND s_1.hours_worked > 0::numeric
          GROUP BY s_1.shift_date
        ), wf_site AS (
         SELECT s_1.shift_date AS report_date,
            COALESCE(d_1.site, 'shared') AS site,
            sum(s_1.hours_worked)::numeric(10,2) AS hours,
            sum(COALESCE(s_1.cost_estimate, s_1.hours_worked * (m.hourly_rate_pence::numeric / 100.0) * (1::numeric + COALESCE(m.on_cost_pct, 12.5) / 100.0)))::numeric(12,2) AS cost
           FROM workforce_shifts s_1
             LEFT JOIN staff_meta m ON m.user_external_id = s_1.user_external_id
             LEFT JOIN workforce_departments d_1 ON d_1.external_id = s_1.department_external_id
          WHERE s_1.hours_worked IS NOT NULL AND s_1.hours_worked > 0::numeric
          GROUP BY s_1.shift_date, (COALESCE(d_1.site, 'shared'))
        ), wf_pivot AS (
         SELECT wf_site.report_date,
            sum(wf_site.cost) FILTER (WHERE wf_site.site = 'pub') AS labour_cost_pub,
            sum(wf_site.cost) FILTER (WHERE wf_site.site = 'cafe') AS labour_cost_cafe,
            sum(wf_site.cost) FILTER (WHERE wf_site.site = 'inn') AS labour_cost_inn,
            sum(wf_site.cost) FILTER (WHERE wf_site.site = 'shared') AS labour_cost_shared,
            sum(wf_site.hours) FILTER (WHERE wf_site.site = 'pub') AS labour_hours_pub,
            sum(wf_site.hours) FILTER (WHERE wf_site.site = 'cafe') AS labour_hours_cafe,
            sum(wf_site.hours) FILTER (WHERE wf_site.site = 'inn') AS labour_hours_inn,
            sum(wf_site.hours) FILTER (WHERE wf_site.site = 'shared') AS labour_hours_shared
           FROM wf_site
          GROUP BY wf_site.report_date
        ), all_dates AS (
         SELECT to_pub.report_date FROM to_pub
        UNION
         SELECT to_sand.report_date FROM to_sand
        UNION
         SELECT ho_1.report_date FROM ho ho_1
        UNION
         SELECT cb_1.report_date FROM cb cb_1
        UNION
         SELECT wf_1.report_date FROM wf wf_1
        )
 SELECT d.report_date,
    p.net_sales AS pub_net_sales,
    p.gross_sales AS pub_gross_sales,
    p.covers AS pub_covers,
    s.net_sales AS sandwich_net_sales,
    s.gross_sales AS sandwich_gross_sales,
    s.covers AS sandwich_covers,
    COALESCE(hf.net_sales,
        CASE WHEN p.net_sales IS NULL AND s.net_sales IS NULL THEN NULL::numeric
             ELSE COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric) END
    )::numeric AS total_net_sales,
    COALESCE(hf.gross_sales,
        CASE WHEN p.gross_sales IS NULL AND s.gross_sales IS NULL THEN NULL::numeric
             ELSE COALESCE(p.gross_sales, 0::numeric) + COALESCE(s.gross_sales, 0::numeric) END
    )::numeric AS total_gross_sales,
    COALESCE(hf.covers,
        CASE WHEN p.covers IS NULL AND s.covers IS NULL THEN NULL::numeric
             ELSE COALESCE(p.covers, 0::numeric) + COALESCE(s.covers, 0::numeric) END
    )::numeric AS total_covers,
    cb.accom_revenue,
    cb.accom_rooms_occupied,
    cb.in_house_count,
    COALESCE(ho.revenue, hf.net_sales,
        CASE WHEN p.net_sales IS NULL AND s.net_sales IS NULL THEN NULL::numeric
             ELSE COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric) END
    )::numeric(12,2) AS total_revenue,
    wf.labour_hours,
    wf.labour_cost_est,
    wf.staff_on_shift,
        CASE
            WHEN COALESCE(ho.revenue, hf.net_sales, COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric)) > 0::numeric
            THEN round(wf.labour_cost_est / COALESCE(ho.revenue, hf.net_sales, COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric)) * 100::numeric, 1)
            ELSE NULL::numeric
        END AS labour_pct,
        CASE
            WHEN wf.labour_hours > 0::numeric
            THEN round(COALESCE(ho.revenue, hf.net_sales, COALESCE(p.net_sales, 0::numeric) + COALESCE(s.net_sales, 0::numeric)) / wf.labour_hours, 2)
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
            WHEN COALESCE(p.net_sales, 0::numeric) > 0::numeric AND wp.labour_cost_pub IS NOT NULL THEN round(wp.labour_cost_pub / p.net_sales * 100::numeric, 1)
            ELSE NULL::numeric
        END AS pub_labour_pct,
        CASE
            WHEN COALESCE(s.net_sales, 0::numeric) > 0::numeric AND wp.labour_cost_cafe IS NOT NULL THEN round(wp.labour_cost_cafe / s.net_sales * 100::numeric, 1)
            ELSE NULL::numeric
        END AS cafe_labour_pct,
        CASE
            WHEN hf.net_sales IS NOT NULL THEN 'head_office'
            WHEN p.net_sales IS NOT NULL OR s.net_sales IS NOT NULL THEN 'per_till_legacy'
            ELSE NULL
        END AS revenue_source,
    ho.revenue AS head_office_revenue
   FROM all_dates d
     LEFT JOIN to_pub p ON p.report_date = d.report_date
     LEFT JOIN to_sand s ON s.report_date = d.report_date
     LEFT JOIN ho_fix hf ON hf.report_date = d.report_date
     LEFT JOIN ho ON ho.report_date = d.report_date
     LEFT JOIN cb ON cb.report_date = d.report_date
     LEFT JOIN wf ON wf.report_date = d.report_date
     LEFT JOIN wf_pivot wp ON wp.report_date = d.report_date;
