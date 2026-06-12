# Invoice pipeline — email to attributed invoice, end-to-end

**Canonical path:** the harvester polls Gmail (accounts `admin`/`info`), writes
one `vendor_invoice_inbox` row per invoice-ish email (idempotency_key dedupe).
The legacy "P2" n8n pipeline and the `invoices` table are superseded — the
dashboard reads `vendor_invoice_inbox` only.

**Extraction ladder** (each rung only fires if the previous got nothing):
1. `pdfplumber` text layer → regex/Haiku field extraction → `extraction_method
   = 'pdf'` (amounts present, high confidence).
2. Text layer empty (scanned/image PDF) → historically dead-ended as
   `pdf_low_conf` (~2k rows). Now: `u281` vision-OCR drain renders pages
   back-to-front (totals live on the LAST page) through a local vision model
   and accepts ONLY when `|net+vat−gross| ≤ 2p` → `vision_ocr` at 0.70
   confidence. Rejects stay untouched for a bigger model (W7800) re-pass.
   `u284` fetches missing PDFs from Gmail (`/message` → walk parts; PDFs often
   arrive as application/octet-stream — match by filename too).
3. No attachment at all (`no_pdf`) = notification emails; nothing to extract.

**Attribution:** the anchor-first counterparty resolver runs in `review` mode
for invoices (cron sweep, forward-only watermark): vendor email domain →
`financial_counterparty` at 0.95 confidence; unknowns queue for one-click
human review at /counterparty-review; ignored/resolved queue rows are terminal
for the sweep. Bank transactions stay in shadow mode until bank_reference
anchors are approved. `counterparty_source` ∈ resolver|human|import — checked
by constraint.

Money truth: header amounts on the row; line items in `vendor_invoice_lines`.
Statements (`is_statement`) are never extraction targets — they have no single
gross.
