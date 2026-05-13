# U44 — Invoice pipeline foundation: end-to-end completion + storage + feedback loop + buckets

**Goal**: make invoice ingestion actually work end-to-end (carry-over from U43), store originals on disk for VAT retention, add a plain-text user-feedback loop, and define Jo's GP-percentage buckets. Pure foundation work — no UI yet (UI lives in U45).

**Remote-doable**: 100%. No sudo, no infra changes.

## Inputs (from Jo, captured here for reference)

- **Wet purchase vendors** (in addition to St Austell): Experience Wine, Tintagel Brewery, Sharps Brewery, Stargazey Spirits, Wadebridge Wines, Westcountry Drinks, LWC.
- **Café vendors**: account number `MAL125`.
- **PDF storage**: NVMe at `/home_ai/storage/invoices/` (~779GB free; restic-backed). 5.5TB `sdd` drive exists but is NTFS Windows + unmounted — sudo to mount, deferred.
- **GP cadence**: daily rolling. Live only if easy & robust.

## Tracks

### Track 1 — Fix invoice-pipeline OAuth/account routing (U43 carry-over, ~45 min)

**Symptom**: invoice-pipeline-v1's Validate Event defaults `account = payload.account || 'personal1'`. The `invoice.detected` event from gmail-ingest-v1 doesn't include `account`. So all invoices try `personal1` Gmail OAuth — fails 400 for invoices actually in admin@/info@.

**Fix**: patch gmail-ingest-v1 to thread `account` from the email into the `invoice.detected` payload (it's already in scope — comes from the Sanitise Email step). Patch workflow_history + workflow_entity, n8n restart.

**Verify**: replay one synthetic admin-account invoice → pipeline completes → `vendor_invoice_inbox` grows by 1.

### Track 2 — Invoice originals to disk (~45 min)

V49 migration: `vendor_invoice_inbox.first_attachment_path` already exists; we just need to populate it.

Update `scripts/u35-invoice-pdf-extract.sh` (and `u36-invoice-haiku-fallback.sh`):
- After successful PDF download from google-fetch, write bytes to:
  ```
  /home_ai/storage/invoices/<YYYY>/<MM>/<gmail_message_id>_<sanitised-filename>.pdf
  ```
- `UPDATE vendor_invoice_inbox SET first_attachment_path = '<path>' WHERE id = $1`
- Idempotent: don't overwrite if file exists with same size.

Make `services/build-dashboard` mount `/home_ai/storage/invoices/:/home_ai/storage/invoices/:ro` so the future UI can serve them. Add `/api/invoice/{id}/pdf` endpoint that streams the file (with path-traversal guard per existing `/viewer/pdf` pattern).

### Track 3 — Plain-text feedback loop (~75 min)

V50 migration: new table `invoice_feedback`:
```sql
CREATE TABLE invoice_feedback (
  id            BIGSERIAL PRIMARY KEY,
  invoice_id    BIGINT REFERENCES vendor_invoice_inbox(id) ON DELETE CASCADE,
  feedback_text TEXT NOT NULL,
  created_at    TIMESTAMPTZ DEFAULT now(),
  created_by    TEXT DEFAULT 'jo',
  ai_proposal   JSONB,      -- Sonnet's interpretation as rule(s)
  applied_at    TIMESTAMPTZ,
  applied_rules JSONB       -- record what vendor_category_rules / status flips landed
);
```

Endpoint: `POST /api/invoice/{id}/feedback {text}`.

New script `u44-feedback-applier.sh` (cron daily 21:30 — before daily-digest):
- Reads `invoice_feedback WHERE applied_at IS NULL`
- For each: Sonnet (tool-use with `input_schema`) classifies the feedback into one of:
  - `flag_as_statement` (UPDATE is_statement=true)
  - `flag_as_ignored` (UPDATE status='ignored')
  - `recategorise` (UPDATE vendor_category)
  - `add_vendor_rule` (INSERT vendor_category_rules) — touches future invoices too
  - `unclear` (logs to needs_review; Telegram notifies)
- Action Queue card: show pending feedback + Sonnet's proposal + [Apply] [Edit] [Skip]
- Never auto-applies rule changes — Jo confirms.

Cost-capped via `ai_usage` (£5/month like reconciliation explainer).

### Track 4 — Bucketing for GP (~30 min)

V51 migration: SQL function + new view.

```sql
CREATE OR REPLACE FUNCTION vendor_category_bucket(canonical TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN canonical IN ('utilities','software','repairs_maintenance') THEN 'head_office'
    WHEN canonical = 'cafe_stock'    THEN 'cafe'
    WHEN canonical = 'wet_purchase'  THEN 'wet'
    WHEN canonical = 'dry_purchase'  THEN 'dry'
    WHEN canonical = 'income'        THEN 'income'   -- guest-booking platform fees etc, excluded
    ELSE 'other'
  END;
$$;
```

Add `bucket` generated column on `vendor_invoice_inbox`.

New view `v_daily_gp` joining bucketed costs to revenue:
```sql
CREATE VIEW v_daily_gp AS
SELECT
  e.report_date,
  e.pub_net_sales,         -- food + wet income (pub)
  e.sandwich_net_sales,    -- café income
  e.accom_revenue,
  SUM(v.net_amount) FILTER (WHERE v.bucket='wet')        AS wet_cost,
  SUM(v.net_amount) FILTER (WHERE v.bucket='dry')        AS dry_cost,
  SUM(v.net_amount) FILTER (WHERE v.bucket='cafe')       AS cafe_cost,
  SUM(v.net_amount) FILTER (WHERE v.bucket='head_office')AS overhead_cost,
  -- GP% per stream
  CASE WHEN COALESCE(e.pub_net_sales,0) > 0
       THEN ROUND(100*(e.pub_net_sales - SUM(v.net_amount) FILTER(WHERE v.bucket='wet'))::numeric / e.pub_net_sales, 1)
  END AS pub_drink_gp_pct,
  -- ... and so on
FROM v_daily_unit_economics e
LEFT JOIN vendor_invoice_inbox v
  ON COALESCE(v.delivery_date, v.invoice_date, v.received_at::date) = e.report_date
 AND v.is_statement = false
 AND v.status NOT IN ('duplicate','ignored')
GROUP BY e.report_date, e.pub_net_sales, e.sandwich_net_sales, e.accom_revenue;
```

Plus a rolling-30d GP view for trend cards.

### Track 5 — Seed vendor rules (~10 min)

```sql
INSERT INTO vendor_category_rules (domain_pattern, category, vendor_display, priority, notes) VALUES
  ('experience.?wine',                'wet_purchase', 'Experience Wine',     50, 'U44 seed'),
  ('tintagel.?brewer',                'wet_purchase', 'Tintagel Brewery',    50, 'U44 seed'),
  ('sharps.?brew',                    'wet_purchase', 'Sharps Brewery',      50, 'U44 seed'),
  ('stargazey',                       'wet_purchase', 'Stargazey Spirits',   50, 'U44 seed'),
  ('wadebridge.?wine',                'wet_purchase', 'Wadebridge Wines',    50, 'U44 seed'),
  ('westcountry|west.?country',       'wet_purchase', 'Westcountry Drinks',  50, 'U44 seed (overlaps with existing rule — check priority)'),
  ('\bLWC\b|^lwc',                    'wet_purchase', 'LWC',                 50, 'U44 seed')
ON CONFLICT (domain_pattern) DO NOTHING;

-- MAL125 is a Caterbook account number — flag matching invoices as cafe_stock
-- (this needs the invoice body / reference field, not domain).
-- We'll defer this until we identify which field carries MAL125.
```

Re-run the backfill categoriser after seeding.

## Acceptance

- [ ] One synthetic admin-account invoice processes end-to-end → vendor_invoice_inbox row, with net/vat/gross extracted and PDF on disk.
- [ ] `SELECT COUNT(*) FROM vendor_invoice_inbox WHERE first_attachment_path IS NOT NULL` ≥ 10 after backfill.
- [ ] `vendor_category_rules` includes the 7 wet vendors.
- [ ] `v_daily_gp` returns rows with non-null `pub_drink_gp_pct` for a day with both pub sales and wet invoices.
- [ ] `POST /api/invoice/{id}/feedback` works; row appears in `invoice_feedback`.
- [ ] Feedback applier runs cleanly (0 candidates on first run is fine).
- [ ] Selftest 51+/52, no new failures.

## Anti-scope

- **No UI changes.** All UI lives in U45.
- **No date picker / filter component.** U45.
- **No live GP push.** Daily rolling only; live-as-it-arrives is a U46 stretch.
- **MAL125 mapping** — defer until we identify which invoice field carries it (likely vendor's own account number in PDF body, not vendor_domain).

## Files in scope

- `/home_ai/postgres/migrations/V49__invoice_first_attachment_path_index.sql` — NEW (light)
- `/home_ai/postgres/migrations/V50__invoice_feedback.sql` — NEW
- `/home_ai/postgres/migrations/V51__vendor_category_bucket_and_gp_view.sql` — NEW
- `/home_ai/scripts/u35-invoice-pdf-extract.sh` — patch to save PDF
- `/home_ai/scripts/u36-invoice-haiku-fallback.sh` — patch likewise
- `/home_ai/scripts/u44-feedback-applier.sh` — NEW (cron 21:30)
- `/home_ai/services/build-dashboard/main.py` — `/api/invoice/{id}/feedback`, `/api/invoice/{id}/pdf`
- `/home_ai/docker-compose.yml` — mount `/home_ai/storage/invoices/` ro into build-dashboard
- workflow_history for `gmail-ingest-v1` (account threading)

## Total

~3.5 hr autonomous.
