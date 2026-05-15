#!/usr/bin/env bash
#
# u61-coverage-audit.sh — walk every (feed, date) in the last 2 years and
# upsert feed_coverage rows. New gaps are surfaced through the existing
# Mission Control "needs your eye" path.
#
# Idempotent — re-runnable. Cron daily 04:30.
#
# Feeds audited:
#   touchoffice_malthouse, touchoffice_sandwich  — touchoffice_fixed_totals
#   caterbook                                    — caterbook_room_nights
#   workforce_shifts                             — workforce_shifts
#   dojo_pub, dojo_cafe                          — dojo_transactions (site=pub/cafe)
#   vendor_invoices                              — vendor_invoice_inbox
#   bank_natwest_atr, bank_natwest_arel,
#   bank_natwest_personal, bank_rbs_cc           — bank_transactions per bank_account

set -euo pipefail

WINDOW_DAYS="${WINDOW_DAYS:-730}"

docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<SQL
\set ON_ERROR_STOP on
SELECT set_config('app.current_entity', 'all',   false);
SELECT set_config('app.current_realm',  'owner', false);

-- 2y of dates as a baseline scaffold.
WITH date_window AS (
    SELECT generate_series(CURRENT_DATE - INTERVAL '${WINDOW_DAYS} days',
                           CURRENT_DATE, '1 day')::date AS d
),

-- per-feed daily counts -----------------------------------------------------

touchoffice_counts AS (
    SELECT site, report_date AS d, COUNT(*) AS n, MAX(scraped_at) AS last_seen
      FROM touchoffice_fixed_totals
     WHERE report_date >= CURRENT_DATE - INTERVAL '${WINDOW_DAYS} days'
     GROUP BY 1, 2
),
caterbook_counts AS (
    SELECT night_date AS d, COUNT(*) AS n
      FROM caterbook_room_nights
     WHERE night_date >= CURRENT_DATE - INTERVAL '${WINDOW_DAYS} days'
     GROUP BY 1
),
workforce_counts AS (
    SELECT shift_date AS d, COUNT(*) AS n
      FROM workforce_shifts
     WHERE shift_date >= CURRENT_DATE - INTERVAL '${WINDOW_DAYS} days'
     GROUP BY 1
),
dojo_counts AS (
    SELECT site, transaction_date AS d, COUNT(*) AS n
      FROM dojo_transactions
     WHERE transaction_date >= CURRENT_DATE - INTERVAL '${WINDOW_DAYS} days'
     GROUP BY 1, 2
),
invoice_counts AS (
    SELECT invoice_date AS d, COUNT(*) AS n
      FROM vendor_invoice_inbox
     WHERE invoice_date >= CURRENT_DATE - INTERVAL '${WINDOW_DAYS} days'
     GROUP BY 1
),
bank_counts AS (
    SELECT
        CASE
            WHEN ba.bank_name = 'RBS Mastercard'                      THEN 'bank_rbs_cc'
            WHEN ba.account_name LIKE 'ATLANTIC ROAD ESTATE%'         THEN 'bank_natwest_arel'
            WHEN ba.account_name LIKE 'ATLANTIC ROAD%'                THEN 'bank_natwest_atr'
            WHEN ba.account_name LIKE 'SANDERCOCK J%'                 THEN 'bank_natwest_personal'
            WHEN ba.account_name LIKE 'Joint%'                        THEN 'bank_natwest_joint'
            WHEN ba.bank_name = 'NatWest' AND ba.account_type='savings' THEN 'bank_natwest_savings'
            ELSE 'bank_other'
        END AS feed,
        bt.transaction_date AS d,
        COUNT(*) AS n
      FROM bank_transactions bt
      JOIN bank_accounts ba ON ba.id = bt.bank_account_id
     WHERE bt.transaction_date >= CURRENT_DATE - INTERVAL '${WINDOW_DAYS} days'
     GROUP BY 1, 2
),

-- combine ------------------------------------------------------------------
all_rows AS (
    SELECT 'touchoffice_' || sites.site AS feed_name, dw.d AS expected_date,
           COALESCE(tc.n, 0) AS n, tc.last_seen
      FROM date_window dw
      CROSS JOIN (SELECT DISTINCT site FROM touchoffice_counts) sites
      LEFT JOIN touchoffice_counts tc ON tc.d = dw.d AND tc.site = sites.site
    UNION ALL
    SELECT 'caterbook', dw.d, COALESCE(cc.n, 0), NULL
      FROM date_window dw
      LEFT JOIN caterbook_counts cc ON cc.d = dw.d
    UNION ALL
    SELECT 'workforce_shifts', dw.d, COALESCE(wc.n, 0), NULL
      FROM date_window dw
      LEFT JOIN workforce_counts wc ON wc.d = dw.d
    UNION ALL
    SELECT 'dojo_' || sites.site, dw.d, COALESCE(dc.n, 0), NULL
      FROM date_window dw
      CROSS JOIN (SELECT DISTINCT site FROM dojo_counts) sites
      LEFT JOIN dojo_counts dc ON dc.d = dw.d AND dc.site = sites.site
    UNION ALL
    SELECT 'vendor_invoices', dw.d, COALESCE(ic.n, 0), NULL
      FROM date_window dw
      LEFT JOIN invoice_counts ic ON ic.d = dw.d
    UNION ALL
    SELECT feeds.feed, dw.d, COALESCE(bc.n, 0), NULL
      FROM date_window dw
      CROSS JOIN (SELECT DISTINCT feed FROM bank_counts) feeds
      LEFT JOIN bank_counts bc ON bc.d = dw.d AND bc.feed = feeds.feed
),
-- compute median per feed for partial-detection -----------------------------
medians AS (
    SELECT feed_name,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY n)::int AS med
      FROM all_rows
     WHERE n > 0
     GROUP BY feed_name
),
classified AS (
    SELECT
        ar.feed_name,
        ar.expected_date,
        ar.n AS row_count,
        ar.last_seen,
        CASE
            -- Some feeds don't run every day (caterbook is event-driven,
            -- vendor_invoices land sporadically, bank txns skip non-working
            -- days). Don't mark these "missing" — mark zero-row days as ok
            -- for any feed whose median is < 1 row/day or whose feed name
            -- matches a sporadic pattern.
            WHEN ar.n = 0 AND (
                 ar.feed_name LIKE 'vendor_invoices'
              OR ar.feed_name LIKE 'caterbook'
              OR ar.feed_name LIKE 'bank_%'
            ) THEN 'ok'
            WHEN ar.n = 0 THEN 'missing'
            WHEN m.med IS NOT NULL AND ar.n < (m.med * 0.4)::int THEN 'partial'
            ELSE 'ok'
        END AS status
      FROM all_rows ar
      LEFT JOIN medians m ON m.feed_name = ar.feed_name
)

INSERT INTO feed_coverage (feed_name, expected_date, row_count, last_scraped,
                           status, audited_at, realm)
SELECT feed_name, expected_date, row_count, last_seen, status, NOW(), 'owner'
  FROM classified
ON CONFLICT (feed_name, expected_date) DO UPDATE
   SET row_count    = EXCLUDED.row_count,
       last_scraped = EXCLUDED.last_scraped,
       status       = EXCLUDED.status,
       audited_at   = EXCLUDED.audited_at;

\echo
\echo === coverage summary ===
SELECT * FROM v_feed_coverage_summary;
\echo
\echo === gaps in last 30d ===
SELECT * FROM v_feed_coverage_recent_gaps LIMIT 30;
SQL
