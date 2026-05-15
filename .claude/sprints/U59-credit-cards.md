# U59 — Credit-card import, statements, inter-account transfers

**Status:** shipped 2026-05-14 (autonomous on remote).

## What landed

### Schema (V73)
- `bank_accounts.account_type` CHECK extended to include `'credit_card'`.
- `card_statements` — one row per (card, statement_date); RLS + realm trigger
  mirrored on `bank_accounts`.
- `account_transfers` — pair-linking table (`src_txn_id`, `dst_txn_id`,
  amount, transfer_date, detection_method, confidence).
- 8 seed rules in `bank_transaction_rules` for RBS Mastercard semantics
  (`PURCHASE` / `PAYMENT` / `FEES` types, interest, DD, FX fee, write-off,
  faster-payment received).
- Views: `v_card_statements_summary`, `v_card_fees_interest_by_month`,
  `v_account_transfers_open`.

### Importers
- `/home_ai/scripts/u59-credit-card-csv-import.sh` — RBS CSV → bank_accounts
  + bank_transactions. Idempotent on `sha256(account|date|value|balance|desc)`.
- `/home_ai/scripts/u59b-credit-card-statement-pdf-import.sh` — RBS PDF →
  `card_statements`. Uses pdfplumber service over HTTP from bot-responder.
  Regex-only parse of page 1 summary. `period_start` derived from previous
  statement_date + 1d.
- `/home_ai/scripts/u59c-account-transfer-link.sh` — pair-matches transfer-
  flagged bank_transactions to opposite-side rows within ±2 days, ±£0.05.

### Live data
- 4 RBS Mastercards under entity=3 (Personal) realm=family:
  ****8864 (dormant), ****2621 (active), ****3092 (most active),
  ****9799 (predecessor of ****2621, retired Jul 2024).
- 477 transactions across the 3 active cards (May 2025 → May 2026).
- 71 PDF statements (Jan 2023 → Dec 2025).
- 269 inter-account transfers paired, £1.5M total flow, including 25
  CC-payment pairings to the NatWest current account.

## Source data
- Drive zip ID `10P9qmQqAevyiFPEKMpXSbQAyhnXXeP13` (52 MB), fetched via Jo's
  `google/jo` OAuth identity (drive scope already wired in the existing
  sidecar's Vault entry).
- Unpacked to `/home_ai/data/credit-card-inbox/2026-05-14/`.

## Open follow-ons (U59 candidates)
1. **Email-trigger ingestion (Jo's choice 2026-05-14):** wire google-fetch
   `/poll-and-emit` (or a new `/credit-card-export-watcher` route) to pick
   up future forwarded RBS CSV+PDF batches automatically and drop them in
   `data/credit-card-inbox/<YYYY-MM-DD>/`. Then trigger u59 + u59b + u59c
   downstream. No cron.
2. **Re-run categoriser regularly:** the catch-all CC rules wrote
   `category_source='rule:CC purchase (catch-all sign)'` directly via
   one-off SQL in this sprint. Promote that into either a new rule shape
   (account_type-aware) or a follow-up SQL stage in u58.
3. **Statement-vs-CSV reconciliation:** for the gap between most recent
   PDF (Dec 2025) and most recent CSV row (May 2026), warn if `closing_balance`
   of last statement ≠ running CSV balance at period_end.
4. **Manual confirmation UI** for the 737 still-unpaired transfer rows.
