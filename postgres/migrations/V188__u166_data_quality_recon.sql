-- =============================================================================
-- V188 — U166: data quality reconciliation slugs
-- =============================================================================
-- Cross-source mismatch detection. Each slug surfaces a specific
-- drift class; a parent slug rolls them up for the digest.
-- =============================================================================

BEGIN;

-- ── recon_dojo_vs_touchoffice_7d ──
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'recon_dojo_vs_touchoffice_7d',
  'Reconciliation — Dojo card take vs TouchOffice sales (last 7d)',
  'U166: per-day per-site, Dojo card take vs TouchOffice department sales totals. Flags >10% drift.',
  E'WITH days AS (
      SELECT generate_series(CURRENT_DATE - 7, CURRENT_DATE - 1, ''1 day''::interval)::date AS d
    ),
    dojo_daily AS (
      SELECT transaction_date AS d,
             location,
             SUM(transaction_amount)::numeric(12,2) AS dojo_gross
        FROM dojo_transactions
       WHERE transaction_date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE - 1
         AND transaction_outcome = ''Authorised''
         AND transaction_type    = ''Sale''
       GROUP BY transaction_date, location
    ),
    to_daily AS (
      SELECT report_date AS d, site,
             SUM(value)::numeric(12,2) AS to_gross
        FROM touchoffice_department_sales
       WHERE report_date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE - 1
       GROUP BY report_date, site
    )
    SELECT
      d.d AS day,
      COALESCE(dj.location, tf.site) AS site,
      COALESCE(dj.dojo_gross, 0) AS dojo,
      COALESCE(tf.to_gross,   0) AS touchoffice,
      COALESCE(tf.to_gross, 0) - COALESCE(dj.dojo_gross, 0) AS diff,
      CASE WHEN COALESCE(tf.to_gross,0) > 0 THEN
        ROUND(100.0 * (COALESCE(tf.to_gross,0) - COALESCE(dj.dojo_gross,0)) / tf.to_gross, 1)
      END AS drift_pct
    FROM days d
    LEFT JOIN dojo_daily dj ON dj.d = d.d
    FULL OUTER JOIN to_daily tf ON tf.d = d.d AND tf.site = dj.location
    ORDER BY d.d DESC, site',
  '{}', 'shared', true, NOW(), 'u166', 'u166'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── recon_bookings_vs_room_nights ──
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'recon_bookings_vs_room_nights',
  'Reconciliation — bookings without matching room nights',
  'U166: accommodation_bookings whose stay dates have no caterbook_room_nights rows.',
  E'SELECT
      ab.id, ab.source, ab.source_ref, ab.guest_name, ab.room,
      ab.checkin_date, ab.checkout_date, ab.status, ab.total_amount,
      (SELECT count(*) FROM caterbook_room_nights crn
        WHERE crn.night_date BETWEEN ab.checkin_date AND ab.checkout_date - 1) AS room_night_rows
    FROM accommodation_bookings ab
   WHERE ab.checkin_date BETWEEN CURRENT_DATE - 60 AND CURRENT_DATE + 60
     AND ab.status NOT IN (''cancelled'', ''no-show'')
     AND NOT EXISTS (
       SELECT 1 FROM caterbook_room_nights crn
       WHERE crn.night_date BETWEEN ab.checkin_date AND ab.checkout_date - 1
     )
   ORDER BY ab.checkin_date DESC
   LIMIT 50',
  '{}', 'shared', true, NOW(), 'u166', 'u166'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── recon_invoices_unmatched_in_xero_21d ──
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'recon_invoices_unmatched_in_xero_21d',
  'Reconciliation — email invoices not yet in Xero (>21d)',
  'U166: vendor_invoice_inbox rows >21d old with no xero_bills link.',
  E'SELECT
      vii.id, vii.received_at::date AS received,
      vii.vendor_name, vii.subject, vii.amount_seen, vii.currency,
      EXTRACT(DAY FROM (NOW() - vii.received_at))::int AS age_days
    FROM vendor_invoice_inbox vii
   WHERE vii.received_at < NOW() - INTERVAL ''21 days''
     AND vii.received_at > NOW() - INTERVAL ''90 days''
     AND NOT EXISTS (SELECT 1 FROM xero_bills xb WHERE xb.inbox_link_id = vii.id)
     AND vii.status NOT IN (''rejected'', ''ignored'')
   ORDER BY vii.received_at',
  '{}', 'shared', true, NOW(), 'u166', 'u166'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── recon_duplicate_attachments ──
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'recon_duplicate_attachments',
  'Reconciliation — duplicate email_attachments',
  'U166: same (gmail_message_id, filename) ingested >1 time.',
  E'WITH dups AS (
      SELECT em.gmail_message_id, ea.filename, count(*) AS n,
             array_agg(ea.id ORDER BY ea.id) AS attachment_ids
        FROM email_attachments ea
        JOIN emails em ON em.id = ea.email_id
       GROUP BY em.gmail_message_id, ea.filename
       HAVING count(*) > 1
    )
    SELECT * FROM dups ORDER BY n DESC, gmail_message_id LIMIT 50',
  '{}', 'shared', true, NOW(), 'u166', 'u166'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── recon_uncategorised_documents ──
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'recon_uncategorised_documents',
  'Reconciliation — invoice-shaped docs left as category=paperless',
  'U166: documents with category=paperless whose title hints invoice/receipt/bill.',
  E'SELECT id, paperless_id, title, created_at::date AS created
      FROM documents
     WHERE category = ''paperless''
       AND (title ILIKE ''%invoice%'' OR title ILIKE ''%receipt%'' OR title ILIKE ''%statement%''
            OR title ILIKE ''%bill%''  OR title ILIKE ''%payment%''  OR title ILIKE ''%order%'')
       AND created_at > NOW() - INTERVAL ''90 days''
     ORDER BY created_at DESC LIMIT 50',
  '{}', 'shared', true, NOW(), 'u166', 'u166'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- ── data_quality_issues_open — rollup ──
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'data_quality_issues_open',
  'Data quality issues — rollup of open recon flags',
  'U166: union of all recon_* slugs as a single severity-ranked list.',
  E'SELECT
      ''dojo_vs_touchoffice_drift''::text AS kind,
      ''high''::text AS severity,
      count(*) AS n,
      ''Cards-vs-EPOS drift > 10% on day''::text AS detail
    FROM (
      SELECT DISTINCT day FROM (
        WITH dojo_daily AS (
          SELECT transaction_date AS d, SUM(transaction_amount)::numeric(12,2) AS g
          FROM dojo_transactions WHERE transaction_date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE - 1
            AND transaction_outcome=''Authorised'' AND transaction_type=''Sale''
          GROUP BY transaction_date
        ),
        to_daily AS (
          SELECT report_date AS d, SUM(value)::numeric(12,2) AS g
          FROM touchoffice_department_sales WHERE report_date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE - 1
          GROUP BY report_date
        )
        SELECT dj.d AS day FROM dojo_daily dj JOIN to_daily tf ON tf.d = dj.d
        WHERE ABS(dj.g - tf.g) > GREATEST(tf.g * 0.10, 50)
      ) sub
    ) drift
  UNION ALL
  SELECT ''bookings_without_room_nights''::text, ''medium''::text, count(*),
         ''Active bookings missing caterbook_room_nights rows''::text
    FROM accommodation_bookings ab
   WHERE ab.checkin_date BETWEEN CURRENT_DATE - 60 AND CURRENT_DATE + 60
     AND ab.status NOT IN (''cancelled'', ''no-show'')
     AND NOT EXISTS (SELECT 1 FROM caterbook_room_nights crn
                     WHERE crn.night_date BETWEEN ab.checkin_date AND ab.checkout_date - 1)
  UNION ALL
  SELECT ''xero_unmatched_21d''::text, ''medium''::text, count(*),
         ''Email invoices >21d unmatched in Xero''::text
    FROM vendor_invoice_inbox vii
   WHERE vii.received_at < NOW() - INTERVAL ''21 days''
     AND vii.received_at > NOW() - INTERVAL ''90 days''
     AND NOT EXISTS (SELECT 1 FROM xero_bills xb WHERE xb.inbox_link_id = vii.id)
     AND vii.status NOT IN (''rejected'', ''ignored'')
  UNION ALL
  SELECT ''duplicate_attachments''::text, ''low''::text, count(*),
         ''email_attachments duplicates''::text
    FROM (
      SELECT em.gmail_message_id, ea.filename FROM email_attachments ea
      JOIN emails em ON em.id = ea.email_id
      GROUP BY em.gmail_message_id, ea.filename HAVING count(*) > 1
    ) dups
  UNION ALL
  SELECT ''uncategorised_paperless_invoices''::text, ''low''::text, count(*),
         ''Invoice-shaped Paperless docs left uncategorised''::text
    FROM documents
   WHERE category = ''paperless''
     AND (title ILIKE ''%invoice%'' OR title ILIKE ''%receipt%'' OR title ILIKE ''%bill%'' OR title ILIKE ''%statement%'')
     AND created_at > NOW() - INTERVAL ''90 days''
   ORDER BY 2, 3 DESC',
  '{}', 'shared', true, NOW(), 'u166', 'u166'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
