-- U204-U214: fixes from boxbot email #127
--   U204: rooms.total.malthouse 7 → 10 (data fix)
--   U205: rooms_week_economics today-anchored (not Monday)
--   U207: dashboard_labour_yesterday — slug unchanged; root cause was
--         touchoffice cron missed 2026-05-20 (DNS); fixed by retry logic
--         in u27-touchoffice-daily.sh
--   U208: (frontend only — removed specials row)
--   U209: NEW slug menu_performance_by_course_7d
--   U210: NEW slugs bar_wage_summary + bar_till_groups_spark_7d
--   U211: NEW slug reviews_rating_spark_30d
--   U212: promoted work_email_kpis + email_tasks_open from owner→shared
--   U213: (frontend only — Trail honest empty state)
--   U214: (diag only — reviews populate fine via u163; surfaced trend slug)

UPDATE static_context
   SET value = jsonb_set(value, '{count}', '10'::jsonb),
       updated_at = NOW()
 WHERE key = 'rooms.total.malthouse';

UPDATE query_whitelist
   SET sql_template = $T$WITH target AS (
              SELECT COALESCE(:date::date, CURRENT_DATE) AS d
          ),
          week AS (
              -- U205: today-anchored (not Monday-anchored)
              SELECT
                  target.d                                AS week_start,
                  (target.d + INTERVAL '7 days')::date    AS week_end_exclusive
              FROM target
          ),
          inventory AS (
              SELECT (value->>'count')::int AS rooms_total
                FROM static_context WHERE key = 'rooms.total.malthouse'
          ),
          nights AS (
              SELECT generate_series(week_start, week_end_exclusive - INTERVAL '1 day', INTERVAL '1 day')::date AS d
                FROM week
          ),
          occupancy AS (
              SELECT n.d, COUNT(DISTINCT ab.id) AS rooms_booked
                FROM nights n
                LEFT JOIN accommodation_bookings ab
                  ON ab.checkin_date <= n.d AND ab.checkout_date > n.d
                 AND ab.status IN ('confirmed','deposit_paid','paid','active')
               GROUP BY n.d
          ),
          stays AS (
              SELECT AVG(checkout_date - checkin_date)::numeric(5,2) AS avg_stay_nights
                FROM accommodation_bookings
               WHERE checkin_date >= (SELECT week_start FROM week)
                 AND checkin_date <  (SELECT week_end_exclusive FROM week)
                 AND status IN ('confirmed','deposit_paid','paid','active')
          )
          SELECT
              (SELECT week_start FROM week)                     AS week_start,
              SUM(rooms_booked)                                 AS room_nights_sold,
              (SELECT rooms_total FROM inventory) * 7           AS room_nights_capacity,
              CASE WHEN (SELECT rooms_total FROM inventory) > 0
                   THEN ROUND(SUM(rooms_booked)::numeric * 100
                              / ((SELECT rooms_total FROM inventory) * 7), 1)
                   ELSE NULL END                                AS pct_occupied,
              (SELECT avg_stay_nights FROM stays)               AS avg_stay_nights,
              (SELECT rooms_total FROM inventory) * 7
                  - SUM(rooms_booked)                           AS room_nights_unsold
          FROM occupancy$T$
 WHERE slug = 'rooms_week_economics';

-- U209: menu performance by course
INSERT INTO query_whitelist (slug, display_name, description, sql_template, active, realm, created_by, approved_at, approved_by, empty_state_md)
VALUES (
  'menu_performance_by_course_7d',
  'Menu performance by course — 7d',
  'U209: ranked PLU sales last 7 days, classified into starter/main/dessert/sides/drink/other.',
  $T$WITH classified AS (
    SELECT
      site, plu_number, descriptor,
      SUM(quantity)::numeric(12,2) AS qty,
      SUM(value)::numeric(14,2) AS gross_gbp,
      CASE
        WHEN descriptor ~* '(burger|fish.{0,3}chip|pork|chicken|beef|lamb|hake|cassoulet|linguine|curry|salad|roast|seafood|picnic|flatfish|6.spiced)' THEN 'main'
        WHEN descriptor ~* '(shrimp|crab cake|pate|mackerel|burrata|chorizo|bocconcini|whitebait|soup|starter)' THEN 'starter'
        WHEN descriptor ~* '(brownie|cheesecake|sticky toffee|eton mess|sundae|ice cream|gelato|sorbet|pavlova|tiramisu|pudding|dessert)' THEN 'dessert'
        WHEN descriptor ~* '(fries|sides|peanuts|bloomer|flatbread|mixed salad|cornish cheddar|truffle)' THEN 'side'
        WHEN descriptor ~* '(korev|rattler|ale|guinness|cruzcampo|harbour|gold ale|lager|cider|pinot|sauvignon|rose|chardonnay|merlot|wine|gin|vodka|whisky|jameson|smirnoff|kraken|rum|cocktail|aperol|negroni|spritz|tequila|tarquin|coastal spring|prestige|cordial|pepsi|coca|lemonade|soda|water|shandy|coffee|tea|cappuccino|americano|latte|espresso|mocha|chai|apple juice|orange juice|ginger beer|fever-tree|tonic|with ice|dash|all together|bottle|heineken|blackcurrant)' THEN 'drink'
        ELSE 'other'
      END AS course
    FROM touchoffice_plu_sales
    WHERE report_date BETWEEN CURRENT_DATE - 6 AND CURRENT_DATE
    GROUP BY site, plu_number, descriptor
  )
  SELECT site, course, plu_number, descriptor, qty, gross_gbp,
         CASE WHEN qty > 0 THEN (gross_gbp / qty)::numeric(10,2) ELSE NULL END AS avg_price,
         RANK() OVER (PARTITION BY site, course ORDER BY gross_gbp DESC) AS rank_in_course
    FROM classified
   WHERE descriptor NOT ILIKE 'accomodation'
   ORDER BY site, course, gross_gbp DESC$T$,
  true, 'shared', 'U209', NOW(), 'U209',
  'No sales yet. Once items are sold, the per-course ranking appears here.'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      approved_at  = EXCLUDED.approved_at,
      realm        = EXCLUDED.realm,
      empty_state_md = EXCLUDED.empty_state_md;

-- U210a: bar wage = FOH only
INSERT INTO query_whitelist (slug, display_name, description, sql_template, active, realm, created_by, approved_at, approved_by)
VALUES (
  'bar_wage_summary',
  'Bar wage % — FOH only, 1/7/30d',
  'U210: bar staff are FOH team. Returns labour, sales, pct per window.',
  $T$WITH params AS (SELECT 1 d UNION ALL SELECT 7 UNION ALL SELECT 30),
       labour AS (
         SELECT p.d, SUM(cost_with_oncost) c
           FROM params p
           JOIN v_daily_labour_by_team l
             ON l.report_date BETWEEN CURRENT_DATE - p.d AND CURRENT_DATE - 1
            AND l.team = 'front_of_house'
          GROUP BY p.d
       ),
       sales AS (
         SELECT p.d, SUM(value) s
           FROM params p
           JOIN touchoffice_department_sales s
             ON s.report_date BETWEEN CURRENT_DATE - p.d AND CURRENT_DATE - 1
            AND s.site = 'malthouse'
          GROUP BY p.d
       )
  SELECT p.d AS days,
         labour.c AS labour,
         sales.s AS sales,
         ROUND((labour.c / NULLIF(sales.s,0) * 100)::numeric, 1) AS pct
    FROM params p
    LEFT JOIN labour USING (d)
    LEFT JOIN sales  USING (d)
   ORDER BY p.d$T$,
  true, 'shared', 'U210', NOW(), 'U210'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      approved_at  = EXCLUDED.approved_at,
      realm        = EXCLUDED.realm;

-- U210b: per-drink-group 7d sparkline
INSERT INTO query_whitelist (slug, display_name, description, sql_template, active, realm, created_by, approved_at, approved_by)
VALUES (
  'bar_till_groups_spark_7d',
  'Bar till — drink group 7d qty spark',
  'U210: per-drink-group 7-day daily qty array, for sparkline per group.',
  $T$WITH classified AS (
    SELECT report_date,
           CASE
             WHEN descriptor ~* '(korev|rattler|ale|guinness|cruzcampo|harbour|gold ale|lager|cider|tintagel gold|cornwalls pride|harbour single|harbour arctic|heineken)' THEN 'beer'
             WHEN descriptor ~* '(pinot|sauvignon|rose|chardonnay|merlot|wine|prestige|coastal spring)' THEN 'wine'
             WHEN descriptor ~* '(cocktail|aperol|negroni|spritz|tarquin|tequila)' THEN 'cocktail'
             WHEN descriptor ~* '(gin|vodka|whisky|jameson|smirnoff|kraken|rum|with ice|dash)' THEN 'spirit'
             WHEN descriptor ~* '(coffee|tea|cappuccino|americano|latte|espresso|mocha|chai|breakfast tea)' THEN 'hot_drink'
             WHEN descriptor ~* '(pepsi|coca|lemonade|soda|water|shandy|cordial|fever-tree|ginger beer|apple juice|orange juice|tonic|all together|blackcurrant|lime|sugar.free)' THEN 'soft_drink'
             ELSE NULL
           END AS grp,
           quantity
      FROM touchoffice_plu_sales
     WHERE site = 'malthouse'
       AND report_date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE - 1
  ),
  days AS (
    SELECT generate_series(CURRENT_DATE - 7, CURRENT_DATE - 1, '1 day'::interval)::date AS d
  ),
  daily AS (
    SELECT grp, d.d, COALESCE(SUM(quantity), 0)::numeric AS qty
      FROM days d
      LEFT JOIN classified c ON c.report_date = d.d
     WHERE grp IS NOT NULL
     GROUP BY grp, d.d
  )
  SELECT grp,
         array_agg(qty ORDER BY d) AS values,
         SUM(qty)::numeric(12,0) AS total_qty
    FROM daily
   GROUP BY grp
   ORDER BY total_qty DESC$T$,
  true, 'shared', 'U210', NOW(), 'U210'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      approved_at  = EXCLUDED.approved_at,
      realm        = EXCLUDED.realm;

-- U211: reviews 30d sparkline + summary
INSERT INTO query_whitelist (slug, display_name, description, sql_template, active, realm, created_by, approved_at, approved_by)
VALUES (
  'reviews_rating_spark_30d',
  'Reviews — 30d rating sparkline + counts',
  'U211: per-day avg rating + count arrays for sparkline, plus 30d totals.',
  $T$WITH days AS (
    SELECT generate_series(CURRENT_DATE - 29, CURRENT_DATE, '1 day'::interval)::date AS d
  ),
  per_day AS (
    SELECT posted_at::date AS d, COUNT(*) AS n, AVG(rating)::numeric AS avg_rating
      FROM guest_reviews
     WHERE rating IS NOT NULL
       AND posted_at::date >= CURRENT_DATE - 29
     GROUP BY 1
  )
  SELECT array_agg(COALESCE(pd.avg_rating, 0) ORDER BY d.d) AS rating_spark,
         array_agg(COALESCE(pd.n, 0) ORDER BY d.d) AS count_spark,
         COALESCE(SUM(pd.n), 0)::int AS total_reviews_30d,
         ROUND(AVG(pd.avg_rating)::numeric, 2) AS avg_rating_30d
    FROM days d
    LEFT JOIN per_day pd USING (d)$T$,
  true, 'shared', 'U211', NOW(), 'U211'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      approved_at  = EXCLUDED.approved_at,
      realm        = EXCLUDED.realm;

-- U212: promote email slugs to shared
UPDATE query_whitelist SET realm='shared' WHERE slug IN ('work_email_kpis','email_tasks_open');
