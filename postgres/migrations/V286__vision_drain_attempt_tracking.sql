-- V286: attempt tracking for the u281 vision-OCR drain.
--
-- Root cause (R2 bake-off, 2026-07-03): the drain ordered its candidate pool
-- ORDER BY received_at DESC LIMIT 30 — the newest 30 docs are exactly the
-- accumulated recent FAILURES, so the hourly cron reground the same stuck docs
-- 24x/day while ~700 older pool docs (75% of which accept per the bench,
-- analysis/r2-ocr-bench/RESULTS.md) were never attempted once.
-- These columns let the drain visit never-attempted docs first and retire
-- documents after 5 failed attempts to the escalation tier.
ALTER TABLE vendor_invoice_inbox
  ADD COLUMN IF NOT EXISTS vision_attempts     integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_vision_attempt timestamptz;

COMMENT ON COLUMN vendor_invoice_inbox.vision_attempts IS
  'u281 vision-OCR drain attempts; >=5 = terminal, leave to escalation tier (V286)';
COMMENT ON COLUMN vendor_invoice_inbox.last_vision_attempt IS
  'last u281 drain attempt; drain orders NULLS FIRST so unattempted docs go first (V286)';

-- partial index matching the drain''s WHERE + ORDER BY
CREATE INDEX IF NOT EXISTS idx_vii_vision_drain
  ON vendor_invoice_inbox (last_vision_attempt ASC NULLS FIRST, received_at DESC)
  WHERE extraction_method='pdf_low_conf'
    AND coalesce(gross_amount,0)=0
    AND coalesce(is_statement,false)=false;
