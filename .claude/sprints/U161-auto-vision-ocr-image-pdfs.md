# U161 — Auto-vision-OCR on image-PDF upload

**Prereqs**: U151b vision-OCR script proven works. paperless-post-consume webhook + U80 mortgage parser already running.

**Realm**: `work` mostly (catches mortgage scans which go to `personal` but pipeline is `work`).

**Remote vs in-person**: 100% remote.

**Why this sprint exists**: U151b processed the 7 stuck Principality PDFs once. But CamScanner uploads will keep coming (Jo scans new statements monthly). Without automation, each upload needs a manual `u151b-reocr-vision.py` run. Pipe the detection + dispatch into the post-consume webhook so it's set-and-forget.

## Tracks

### T1 — Image-PDF detection rule (~30 min)

**Build**: in `services/build-dashboard/main.py` ingest-from-paperless handler (~line 3527):

After insert into `documents`, check `ocr_text`:
- length < 50 chars, OR
- matches `^(CamScanner\s*)+$` after whitespace collapse, OR
- repeats a single short phrase >5 times

→ Mark document as `needs_vision_ocr=true` (new column via V184).

**Acceptance**: doc 33 (CamScanner) classified as `needs_vision_ocr=true`; doc 31 likewise; modern typed PDFs stay false.

### T2 — Vision-OCR job dispatch (~45 min)

**Build**:
- New table `vision_ocr_jobs` (V184): document_id, status (pending/running/done/failed), attempts, error, started_at, completed_at.
- When ingest sets `needs_vision_ocr=true`, INSERT a vision_ocr_jobs row.
- New cron `*/15 * * * * /home_ai/scripts/u161-vision-ocr-worker.py` — picks pending job, calls u151b logic on that single doc, updates job status.

**Acceptance**: uploading a CamScanner PDF results in job row + worker picks it up + extracted data appears in mortgage_statement_periods (or other downstream).

### T3 — U151b refactor into library (~30 min)

**Build**: extract the per-document vision-OCR logic from u151b into a reusable function `scripts/lib/vision_ocr.py`:
- `process_image_pdf(pdf_path, document_id, anthropic_key, pg_dsn) -> dict`
- Returns: pages processed, periods extracted, errors

Both u151b (batch backfill) and u161 (worker) use the same library.

**Acceptance**: shared module imported by both; single source of truth.

### T4 — Cost guard (~20 min)

**Build**: vision-OCR is more expensive than Tesseract — guard against runaway:
- `vision_ocr_jobs` worker bails if `ai_usage.cost_gbp` for `CAP_VISION_OCR` in last 24h > £0.50.
- Alert via Telegram if guard trips.
- Manual override via env var `VISION_OCR_OVERRIDE=1`.

**Acceptance**: synthetic test of guard fires alert.

### T5 — Backfill detection (~15 min)

**Build**: one-shot query to find existing documents with image-only OCR that haven't been processed yet (not in vision_ocr_jobs done set). Insert pending jobs for each.

**Acceptance**: backfill picks up any past CamScanner uploads beyond the 7 mortgage docs.

## Done criteria

- New CamScanner upload → auto-detected → auto-OCR'd via Haiku-vision → data extracted within 30 min of arrival.
- Cost guard prevents runaway spend.
- u151b retained as one-shot tool; u161 is the continuous loop.

## Risk

Low. The vision-OCR pattern is proven by U151b. This is plumbing + automation.

Related: [[feedback-mortgage-scans-camscanner-ocr]] (the bug), [[u151b-reocr-vision]] (the manual fix), [[feedback-budget-split]] (quota awareness).
