# 2026-05-15 — U76: process older emails + invoices

Two backfill scripts pulled historic Gmail invoice-shaped messages:

- **u34-invoice-backfill 180** — admin@ + info@malthousetintagel.com aliases. seen=300 / ingested=12 (rest deduped via idempotency_key).
- **u29-vendor-invoices-backfill 365** — jolyboxbot@gmail.com filter for invoice/statement subjects. inserted=76 / skipped=11 / noise_filtered=90.

After triage:
- 22 → extracted (SaaS recurring, real invoice emails)
- 66 → ignored (statements, guest noise, no-PDF notifications, OTA bookings)

## Brother scans (5 fresh)

| doc | category | meaning |
|---|---|---|
| 20 | mortgage_statement | Principality 295905-02 Q4 2024 → linked to mortgage_accounts.id=1 |
| 21 | mortgage_statement | **NEW: Principality 284512-03 Q4 2019** — interest-only loan in Mr J Sandercock's personal name. £201,058.22 @ 2019-12-31. Property TBD. |
| 22 | mortgage_statement | Principality 295905-02 Q3 2021 (£217k closing) → linked to mortgage_accounts.id=1 |
| 23 | merchant_statement | Clover card-processing statement, pub, March 2026. vendor_invoice_inbox row ignored (statements live in their own surface) |
| 24 | utility_bill | South West Water bill for Shop & Flat 1 Castle Rd. £1,105.64. Linked to property 1 Castle Road. |

## Open follow-up
- Loan 284512-03: which property does this cover? Was the £201,058 in 2019 paid down? Needs Jo to confirm + supply a newer statement.
- Clover statements should eventually feed staging.payments reconciliation (parallel to Dojo). For now they sit as documents.
