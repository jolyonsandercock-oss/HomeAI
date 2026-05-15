# Idempotency-key audit

Generated 2026-05-15T20:30:23+01:00. Read-only.

## Convention (per AGENTS.md rule 7)

- `events.idempotency_key` — no UNIQUE; intentional re-emit tolerated.
- Other tables — UNIQUE constraint enforced; populated on every insert.

## Per-table state

| table | rows | null idempotency | unique-violation potential | enforced UNIQUE |
|---|---|---|---|---|
| public.accommodation_daily_reports | 0 | 0 | 0  | ✓ |
| public.bank_transactions | 10141 | 0 | 0  | ✓ |
| public.caterbook_daily_snapshots | 144 | 0 | 0  | ✓ |
| public.caterbook_email_reports | 144 | 0 | 0  | ✓ |
| public.caterbook_observations | 1028 | 0 | 0  | ✓ |
| public.child_events | 112 | 0 | 0  | ✓ |
| public.clover_batches | 33 | 0 | 0  | — |
| public.epos_daily_reports | 0 | 0 | 0  | ✓ |
| public.event_idempotency_keys | 1043 | 0 | 0  | ✓ |
| public.events | 1723 | 2 | 127 🟡 nulls | (by design, none) |
| public.events_2026_04 | 0 | 0 | 0  | — |
| public.events_2026_05 | 1723 | 2 | 127 🟡 nulls | — |
| public.events_2026_06 | 0 | 0 | 0  | — |
| public.events_2026_07 | 0 | 0 | 0  | — |
| public.events_overflow | 0 | 0 | 0  | — |
| public.google_api_calls | 3394 | 3394 | 3394 🟡 nulls | — |
| public.invoices | 0 | 0 | 0  | ✓ |
| public.till_reconciliation | 121 | 0 | 0  | ✓ |
| public.touchoffice_department_sales | 2446 | 0 | 0  | ✓ |
| public.touchoffice_fixed_totals | 6428 | 0 | 0  | ✓ |
| public.touchoffice_plu_sales | 31833 | 0 | 0  | ✓ |
| public.vendor_invoice_inbox | 285 | 0 | 0  | ✓ |

## Convention violations
Any row in the table above marked 🔴 means UNIQUE was claimed but duplicates exist. None expected.
