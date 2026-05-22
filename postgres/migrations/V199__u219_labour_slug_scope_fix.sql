-- U219: dashboard_labour_yesterday — pub_sales scope must match pub_labour
--
-- Pub labour pool = kitchen + front_of_house + accommodation teams.
-- Pub sales used to be TouchOffice malthouse POS ONLY, which excluded the
-- accommodation revenue that the accom team supports. Net result: pub %
-- inflated by ~5-6pp vs reality (e.g. 7d combined 31.8% → 26.7% after fix).
--
-- Discovery: 2026-05-22 Jo flagged the 7d/30d avg boxes in screenshot.
-- Cafe scope unchanged (sandwich POS only — cafe team has no off-POS revenue).

UPDATE query_whitelist
   SET sql_template = $T$WITH windows(w) AS (VALUES (1),(7),(30)),
    labour_by_day AS (
      SELECT report_date AS d,
             SUM(cost_with_oncost) FILTER (WHERE team IN ('kitchen','front_of_house','accommodation')) AS pub_labour,
             SUM(cost_with_oncost) FILTER (WHERE team = 'cafe') AS cafe_labour
        FROM v_daily_labour_by_team
       WHERE report_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
       GROUP BY report_date
    ),
    sales_by_day AS (
      SELECT d.d,
             -- Pub sales = TouchOffice POS + accommodation revenue (matches
             -- pub_labour which already includes the accommodation team)
             COALESCE((SELECT SUM(value)          FROM touchoffice_department_sales WHERE report_date=d.d AND site='malthouse'), 0)
           + COALESCE((SELECT SUM(rate_per_night) FROM caterbook_room_nights        WHERE night_date=d.d), 0) AS pub_sales,
             COALESCE((SELECT SUM(value)          FROM touchoffice_department_sales WHERE report_date=d.d AND site='sandwich'),  0) AS cafe_sales
        FROM generate_series(CURRENT_DATE - 30, CURRENT_DATE - 1, '1 day'::interval) d(d)
    )
    SELECT w.w AS window_days,
           ROUND(AVG(l.pub_labour)::numeric, 2)  AS pub_labour_avg,
           ROUND(AVG(s.pub_sales)::numeric,  2)  AS pub_sales_avg,
           ROUND(AVG(l.cafe_labour)::numeric, 2) AS cafe_labour_avg,
           ROUND(AVG(s.cafe_sales)::numeric,  2) AS cafe_sales_avg
      FROM windows w
      LEFT JOIN labour_by_day l ON l.d >= CURRENT_DATE - w.w AND l.d < CURRENT_DATE
      LEFT JOIN sales_by_day  s ON s.d = l.d
     GROUP BY w.w
     ORDER BY w.w$T$
 WHERE slug='dashboard_labour_yesterday';
