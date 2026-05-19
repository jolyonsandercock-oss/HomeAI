-- =============================================================================
-- V151 — U134 T3: per-day strip extras (staff by team, rota cost, rooms left)
-- =============================================================================

BEGIN;

-- Total rentable rooms (default — Jo confirms; adjust value here if not 7).
INSERT INTO static_context (key, value, realm)
VALUES ('rooms.total.malthouse', '{"count": 7}'::jsonb, 'work')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    ('dashboard_week_strip_extras',
     'Week strip — staff/rota/rooms by day',
     'Per-day rota head count by team, total rota cost, room inventory (booked / total / left). Merged with dashboard_week_strip on the frontend.',
     $sql$WITH dates AS (
            SELECT generate_series(CURRENT_DATE, CURRENT_DATE + INTERVAL '6 days', INTERVAL '1 day')::date AS d
          ),
          rota AS (
            SELECT shift_date AS d,
                   COUNT(*)                                                                       AS staff_total,
                   COUNT(*) FILTER (WHERE team = 'kitchen')                                       AS staff_kitchen,
                   COUNT(*) FILTER (WHERE team = 'front_of_house')                                AS staff_foh,
                   COUNT(*) FILTER (WHERE team = 'accommodation')                                 AS staff_accom,
                   COUNT(*) FILTER (WHERE team = 'cafe')                                          AS staff_cafe,
                   SUM(shift_cost)::numeric(10,2)                                                 AS rota_cost_total
              FROM v_workforce_shifts_costed
             WHERE shift_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '6 days'
             GROUP BY shift_date
          ),
          rooms AS (
            SELECT dates.d,
                   COUNT(DISTINCT ab.id) AS rooms_booked
              FROM dates
              LEFT JOIN accommodation_bookings ab
                ON ab.checkin_date <= dates.d AND ab.checkout_date > dates.d
               AND ab.status IN ('confirmed','deposit_paid','paid','active')
             GROUP BY dates.d
          ),
          inventory AS (
            SELECT (value->>'count')::int AS rooms_total
              FROM static_context WHERE key = 'rooms.total.malthouse'
          )
          SELECT dates.d AS day,
                 COALESCE(rota.staff_total, 0)    AS staff_total,
                 COALESCE(rota.staff_kitchen, 0)  AS staff_kitchen,
                 COALESCE(rota.staff_foh, 0)     AS staff_foh,
                 COALESCE(rota.staff_accom, 0)   AS staff_accom,
                 COALESCE(rota.staff_cafe, 0)    AS staff_cafe,
                 COALESCE(rota.rota_cost_total, 0)::numeric(10,2) AS rota_cost,
                 (SELECT rooms_total FROM inventory) AS rooms_total,
                 COALESCE(rooms.rooms_booked, 0) AS rooms_booked,
                 GREATEST(0, (SELECT rooms_total FROM inventory) - COALESCE(rooms.rooms_booked, 0)) AS rooms_left
            FROM dates
            LEFT JOIN rota  ON rota.d  = dates.d
            LEFT JOIN rooms ON rooms.d = dates.d
           ORDER BY dates.d$sql$,
     '{}'::jsonb, 'table',
     true, 'V151-U134T3', NOW(), 'V151-U134T3',
     'Per U134 T3 plan — strip extras.', 'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       active       = true,
       approved_at  = NOW();

COMMIT;
