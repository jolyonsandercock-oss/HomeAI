-- =============================================================================
-- V76b — add top_purchases_window slug to query_whitelist
-- =============================================================================
-- Enables "how much milk last 60 days" / "top ice-cream flavours this year"
-- via the /finance NL ask box.
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
    (slug, display_name, description, intent_examples, sql_template,
     param_schema, result_format, active, entity_id, created_by,
     approved_at, approved_by, realm)
VALUES
('top_purchases_window',
 'Top purchases by product family in the last N days',
 'Roll-up of vendor_invoice_lines joined to product_canonical. Use to ask '
 '"how much milk did I buy", "what ice cream flavours have I bought most", '
 '"what did I spend on packaging this year". When a family is provided '
 'filters to that family; when omitted returns the top families by spend.',
 ARRAY[
   'how much milk did I buy',
   'top ice cream flavours',
   'what did I spend on packaging this year',
   'how much wine in the last 60 days'
 ],
$$
SELECT
    COALESCE(canonical_family, 'uncategorised') AS family,
    COALESCE(canonical_name, raw_description)   AS product,
    COUNT(*)                                    AS line_count,
    SUM(qty)::numeric(12,3)                     AS total_qty,
    SUM(line_net)::numeric(12,2)                AS total_net,
    MAX(invoice_date)                           AS last_invoice
  FROM v_invoice_lines_resolved
 WHERE invoice_date >= CURRENT_DATE - :days * INTERVAL '1 day'
   AND (
        :family = ''
     OR canonical_family = :family
     OR raw_description ILIKE '%' || :family || '%'
   )
 GROUP BY 1, 2
 ORDER BY total_net DESC NULLS LAST
 LIMIT :limit
$$,
 '{"days":   {"type":"int","min":1,"max":3650,"required":false,"default":60},
   "family": {"type":"string","required":false,"default":""},
   "limit":  {"type":"int","min":1,"max":200,"required":false,"default":25}}'::jsonb,
 'table', true, 3, 'system_v76b', now(), 'system_v76b', 'owner')
ON CONFLICT (slug) DO UPDATE SET
    display_name     = EXCLUDED.display_name,
    description      = EXCLUDED.description,
    intent_examples  = EXCLUDED.intent_examples,
    sql_template     = EXCLUDED.sql_template,
    param_schema     = EXCLUDED.param_schema,
    approved_at      = COALESCE(query_whitelist.approved_at, EXCLUDED.approved_at);

COMMIT;
