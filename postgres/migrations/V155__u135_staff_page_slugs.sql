-- =============================================================================
-- V155 — U135 T4: staff page slugs (6 new)
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    -- 1. Tanda sync status
    ('staff_tanda_sync_status',
     'Tanda sync status',
     'Last successful workforce + timesheets sync. Drives the staff-page Tanda health row.',
     $sql$SELECT
            (SELECT max(last_synced_at) FROM workforce_users)               AS users_last_sync,
            (SELECT count(*) FROM workforce_users WHERE active)             AS active_user_count,
            (SELECT max(shift_date) FROM workforce_shifts)                  AS latest_shift_date,
            (SELECT count(*) FROM workforce_shifts WHERE shift_date >= CURRENT_DATE) AS upcoming_shifts,
            EXTRACT(EPOCH FROM (NOW() - (SELECT max(last_synced_at) FROM workforce_users)))/3600 AS hours_since_user_sync$sql$,
     '{}'::jsonb, 'table', true, 'V155-U135T4', NOW(), 'V155-U135T4',
     'Per U135 T4 plan.', 'work'),

    -- 2. Staff on rota today (date-aware)
    ('staff_on_rota_today',
     'Staff on rota — target date',
     'Rota for a given date (default = today). Returns one row per shift with team, times, hours, cost.',
     $sql$SELECT w.user_external_id,
                w.full_name,
                w.team,
                w.start_time,
                w.end_time,
                w.hours_worked,
                w.shift_cost
           FROM v_workforce_shifts_costed w
          WHERE w.shift_date = COALESCE(:date::date, CURRENT_DATE)
          ORDER BY w.team, w.start_time$sql$,
     '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
     'table', true, 'V155-U135T4', NOW(), 'V155-U135T4',
     'Per U135 T4 plan.', 'work'),

    -- 3. Per-staff revenue attribution (proportional by team-hours)
    --
    -- Allocation rule: each team's revenue (touchoffice_department_sales,
    -- mapped via site) gets divided proportionally across that team's hours
    -- worked in the window. Team→site map: cafe→sandwich; all others→malthouse.
    ('staff_attribution_per_hour',
     'Staff attribution — revenue per hour',
     'Per-staff cost vs attributed revenue across a date window. Attribution = (staff hours / team hours) × team site revenue.',
     $sql$WITH win AS (
              SELECT COALESCE(:date_from::date, CURRENT_DATE - INTERVAL '7 days')::date AS d_from,
                     COALESCE(:date_to::date,   CURRENT_DATE)::date                     AS d_to
          ),
          shifts AS (
              SELECT w.user_external_id, w.full_name, w.team,
                     SUM(w.hours_worked) AS hours,
                     SUM(w.shift_cost)   AS cost
                FROM v_workforce_shifts_costed w, win
               WHERE w.shift_date BETWEEN win.d_from AND win.d_to
               GROUP BY w.user_external_id, w.full_name, w.team
          ),
          team_hours AS (
              SELECT team, SUM(hours) AS total_hours FROM shifts GROUP BY team
          ),
          team_revenue AS (
              SELECT CASE WHEN t.site = 'sandwich' THEN 'cafe' ELSE 'pub_combined' END AS team_bucket,
                     SUM(t.value) AS revenue
                FROM touchoffice_department_sales t, win
               WHERE t.report_date BETWEEN win.d_from AND win.d_to
               GROUP BY 1
          )
          SELECT s.user_external_id,
                 s.full_name,
                 s.team,
                 s.hours,
                 s.cost::numeric(10,2),
                 CASE s.team
                   WHEN 'cafe' THEN (SELECT revenue FROM team_revenue WHERE team_bucket='cafe')
                   ELSE                (SELECT revenue FROM team_revenue WHERE team_bucket='pub_combined')
                 END * (s.hours / NULLIF((SELECT total_hours FROM team_hours WHERE team=s.team), 0)) AS attributed_revenue,
                 CASE WHEN s.hours > 0
                      THEN ROUND(
                        ((CASE s.team
                           WHEN 'cafe' THEN (SELECT revenue FROM team_revenue WHERE team_bucket='cafe')
                           ELSE                (SELECT revenue FROM team_revenue WHERE team_bucket='pub_combined')
                         END * (s.hours / NULLIF((SELECT total_hours FROM team_hours WHERE team=s.team), 0)))
                         - s.cost) / s.hours, 2)
                      ELSE NULL
                 END AS gp_per_hour
            FROM shifts s
           ORDER BY gp_per_hour DESC NULLS LAST$sql$,
     '{"date_from": {"type":"string","format":"date","optional":true},
       "date_to":   {"type":"string","format":"date","optional":true}}'::jsonb,
     'table', true, 'V155-U135T4', NOW(), 'V155-U135T4',
     'Per U135 T4 plan. Allocation = staff-hours-share × team site revenue.',
     'work'),

    -- 4. Upcoming holidays — next 28 days from a target date
    ('staff_upcoming_holidays',
     'Upcoming staff holidays',
     'Approved + pending holiday requests starting within the next 28 days.',
     $sql$SELECT h.id, h.staff_id, h.requested_start, h.requested_end,
                h.days_requested, h.status, h.notes,
                COALESCE(s.first_name || ' ' || s.last_name, '?') AS staff_name
           FROM holiday_requests h
           LEFT JOIN staff s ON s.id = h.staff_id
          WHERE h.requested_start BETWEEN COALESCE(:date::date, CURRENT_DATE)
                                     AND COALESCE(:date::date, CURRENT_DATE) + INTERVAL '28 days'
          ORDER BY h.requested_start$sql$,
     '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
     'table', true, 'V155-U135T4', NOW(), 'V155-U135T4',
     'Per U135 T4 plan.', 'work'),

    -- 5. Birthdays in next 30 days (extracted from Tanda DOB raw_payload)
    ('staff_birthdays_next_30d',
     'Staff birthdays — next 30 days',
     'Active employees whose birthday (from Tanda DOB) falls in the next 30 days.',
     $sql$WITH dobs AS (
              SELECT external_id, full_name,
                     (raw_payload->>'date_of_birth')::date AS dob
                FROM workforce_users
               WHERE active = true
                 AND raw_payload ? 'date_of_birth'
                 AND raw_payload->>'date_of_birth' IS NOT NULL
                 AND raw_payload->>'date_of_birth' <> ''
          ),
          this_year_bday AS (
              SELECT external_id, full_name, dob,
                     make_date(EXTRACT(YEAR FROM CURRENT_DATE)::int,
                               EXTRACT(MONTH FROM dob)::int,
                               EXTRACT(DAY FROM dob)::int) AS bday_this_year
                FROM dobs
          )
          SELECT external_id, full_name, dob,
                 CASE WHEN bday_this_year < CURRENT_DATE
                      THEN bday_this_year + INTERVAL '1 year'
                      ELSE bday_this_year END::date AS next_bday,
                 (EXTRACT(YEAR FROM CURRENT_DATE)::int - EXTRACT(YEAR FROM dob)::int)
                   + CASE WHEN bday_this_year < CURRENT_DATE THEN 1 ELSE 0 END AS age_then
            FROM this_year_bday
           WHERE (CASE WHEN bday_this_year < CURRENT_DATE
                        THEN bday_this_year + INTERVAL '1 year'
                        ELSE bday_this_year END)
                 <= CURRENT_DATE + INTERVAL '30 days'
           ORDER BY next_bday$sql$,
     '{}'::jsonb, 'table', true, 'V155-U135T4', NOW(), 'V155-U135T4',
     'Per U135 T4 plan.', 'work'),

    -- 6. Dojo card tips for a target date
    ('staff_dojo_tips_today',
     'Dojo gratuity total — target date',
     'Sum of gratuity_amount across Dojo transactions for the date. Per-staff allocation deferred to Tronc work in U137; this returns site-level pool only.',
     $sql$SELECT (SELECT CASE WHEN mid = '476621462111863' THEN 'pub' ELSE 'cafe' END FROM dojo_transactions WHERE mid = d.mid LIMIT 1) AS site,
                COUNT(*)                                    AS tx_count,
                SUM(gratuity_amount)::numeric(10,2)         AS gratuity_total
           FROM dojo_transactions d
          WHERE d.transaction_date = COALESCE(:date::date, CURRENT_DATE)
            AND gratuity_amount > 0
          GROUP BY d.mid
          ORDER BY site$sql$,
     '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
     'table', true, 'V155-U135T4', NOW(), 'V155-U135T4',
     'Per U135 T4 plan.', 'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       param_schema = EXCLUDED.param_schema,
       active       = true,
       approved_at  = NOW();

COMMIT;
