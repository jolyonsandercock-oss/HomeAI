# 2026-05-15 — U82: mine sent Gmail for missing mortgage statements

Query: search 'jo' Gmail account for `in:sent has:attachment statement (hodgsons OR atc)`
plus broader principality/loan-account queries. 125 PDF attachments matched
across ~25 emails to accountants Hodgsons/ATC.

Filtered to mortgage statements only (excluded bank statements, statutory
accounts, leases, EPCs, facility letters): 8 PDFs. Saved to
/mnt/shared_storage/scans/inbox; Paperless OCR'd them within ~90s.

## Critical correction

The OCR revealed the **actual** loan refs include suffixes I hadn't captured:

| Was | Actual | Property |
|---|---|---|
| 967002 | 967002-01 | 1 Castle Road |
| 967003 | 967003-10 | 2+3 Salutations |
| 295178 | 295178-07 | Olde Malthouse (pub, closed) |

Updated `mortgage_accounts.account_ref` to the full suffixed form so the
parser's exact-match lookup hits.

## Balances we now know

Was unknown:
- 967002-01: **£225,347.15 @ 2025-03-31**
- 967003-10: **£225,608.67 @ 2025-03-31**

Already known but worth restating:
- 295905-02: £224,655.66 @ 2025-12-31

**Total secured borrowing: £675,611.48** — was £177,103 before this dig.

## Net worth recalculation

- Property value: £2,195,000 (unchanged)
- Net cash: -£12,236 (unchanged)
- Secured: £675,611 (was £177,103)
- Unsecured: £22,006 (unchanged)
- **Net worth: £1,485,147** (was £1,983,655)

The £450k delta is real debt that wasn't visible because we had no scans
for the active 967002/967003 loans — the parser surfaced 5 quarterly
statements per loan from inside an old `Principality_scans.pdf` Jo had
sent to accountants in 2024-2025.

## Still missing
- 295905-02: 11 quarters (mostly 2020 + 2026 Q1)
- 967002-01: 5 quarters (mid-2022 + 2025 Q2-Q4)
- 967003-10: 5 quarters (same)
- 219125304: no scans, unknown property

Telegram sent. Updated inventory email sent (message_id 19e2cdfe12a7f8ae).
