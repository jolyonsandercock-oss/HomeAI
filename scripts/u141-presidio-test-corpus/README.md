# U141 — Presidio PII test corpus

50 synthetic UK-context documents, each seeded with at least one instance of every
PII type the system needs to redact. Used by `scripts/u141-validate-presidio.sh`
to assert recogniser coverage.

**No real personal data here** — all names, addresses, phone numbers, account
numbers, NI numbers, VAT numbers, postcodes etc. are fabricated and verified
against publicly-available format rules only.

## Files

- `corpus/01-hospitality-invoice-*.txt` — fake supplier invoices (10)
- `corpus/02-property-tenancy-*.txt` — fake tenancy/property docs (10)
- `corpus/03-employment-*.txt` — fake employment offers, payslips (10)
- `corpus/04-booking-confirmation-*.txt` — fake hotel/restaurant bookings (10)
- `corpus/05-mixed-correspondence-*.txt` — fake free-form letters (10)

## Expected recogniser hits per file

Each file in the corpus declares its expected detections as a `# EXPECT:` header
line containing comma-separated `ENTITY_TYPE:count` pairs. The validator
asserts the Presidio analyzer returns ≥ those counts.

## Running

```
bash scripts/u141-validate-presidio.sh
```

Exits 0 if every file passes; 1 with a diff if any recogniser undercounts.
