-- V226 — U235: enrich the invoice_line branch of v_research_corpus.
-- Before: only the line description was searchable/shown, so RAG answers could not
-- state amounts ("passages do not include monetary values"). Now the title carries
-- vendor + gross (always shown verbatim to the synthesis model), body carries the full
-- structured detail, and ts includes the vendor name for sharper FTS recall.
-- email + document branches unchanged.

CREATE OR REPLACE VIEW v_research_corpus AS
 SELECT 'email'::text AS source_table,
    e.id AS source_id,
    e.tsv AS ts,
    e.subject AS title,
    e.body_text AS body,
    e.received_at AS event_at,
    e.account,
    e.entity_id,
    e.realm
   FROM emails e
  WHERE e.tsv IS NOT NULL
UNION ALL
 SELECT 'invoice_line'::text AS source_table,
    vil.id AS source_id,
    to_tsvector('english', concat_ws(' ', vil.description, vii.vendor_name)) AS ts,
    -- title: description + vendor + gross — always shown verbatim in the RAG context
    concat_ws(' — ',
      vil.description,
      NULLIF(vii.vendor_name, ''),
      CASE WHEN vil.line_gross IS NOT NULL THEN 'gross £' || vil.line_gross::text END
    ) AS title,
    -- body: full structured line detail (drives the snippet headline)
    concat_ws(' · ',
      NULLIF(vii.vendor_name, ''),
      CASE WHEN vil.qty        IS NOT NULL THEN 'qty ' || vil.qty::text END,
      CASE WHEN vil.unit_price IS NOT NULL THEN 'unit £' || vil.unit_price::text END,
      CASE WHEN vil.line_net   IS NOT NULL THEN 'net £' || vil.line_net::text END,
      CASE WHEN vil.line_vat   IS NOT NULL THEN 'vat £' || vil.line_vat::text END,
      CASE WHEN vil.line_gross IS NOT NULL THEN 'gross £' || vil.line_gross::text END,
      CASE WHEN vil.department  IS NOT NULL THEN 'dept ' || vil.department END,
      CASE WHEN vii.invoice_date IS NOT NULL THEN 'invoice ' || vii.invoice_date::text END
    ) AS body,
    vii.invoice_date::timestamptz AS event_at,
    vii.account,
    vii.entity_id,
    vii.realm
   FROM vendor_invoice_lines vil
     JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id
UNION ALL
 SELECT 'document'::text AS source_table,
    d.id AS source_id,
    d.ocr_tsv AS ts,
    d.title,
    d.ocr_text AS body,
    d.created_at AS event_at,
    NULL::text AS account,
    d.entity_id,
    d.realm
   FROM documents d
  WHERE d.ocr_tsv IS NOT NULL;
