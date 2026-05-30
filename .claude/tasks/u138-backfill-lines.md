Task for Claude Code:

There are 521 invoices in `vendor_invoice_inbox` that have no extracted line items in `vendor_invoice_lines`. The existing cron (u35-invoice-pdf-extract.sh) skips them because their `extraction_method` is already set to `haiku` or `haiku_no_text` — it only targets rows with NULL extraction_method.

The invoices exist on JolyBox (100.104.82.53, SSH as joly). Working dir: /home_ai

Required:
1. Identify the 521 invoices without line items (query: vendor_invoice_inbox vii WHERE NOT EXISTS SELECT 1 FROM vendor_invoice_lines vil WHERE vil.invoice_id = vii.id AND status NOT IN ('duplicate','ignored'))
2. Re-run PDF text extraction on them — they have PDF files at `first_attachment_path` or `pdf_local_path`
3. Then re-run Haiku line item extraction to populate `vendor_invoice_lines`
4. Ensure the pipeline is idempotent (will not re-process already-done invoices)
5. Update the extraction_method to reflect the re-run

The existing scripts that do similar work:
- /home_ai/scripts/u35-invoice-pdf-extract.sh — fetches PDFs and extracts text via pdfplumber
- /home_ai/scripts/u36-invoice-haiku-fallback.sh — re-extracts via Haiku for low-confidence rows

Both run inside docker containers:
- u35 runs via `docker exec homeai-playwright python << 'PYEOF'`
- u36 runs via `docker exec homeai-bot-responder python << 'PYEOF'`

The key issue is that u35's SQL query only looks for rows WHERE extraction_method IS NULL. You need to expand it or create a targeted backfill script that also processes haiku/haiku_no_text rows that have no line items.

Prioritise invoices that are most recent (last 90 days) first. The user wants to categorise line items on the tasks page and cannot do that for invoices without parsed lines.

Do NOT modify the existing u35/u36 scripts — create a separate `scripts/u138-backfill-lines.sh` that handles the haiku rows specifically.
