# Bot-instructions bi#59 + bi#60 — mortgage_accounts corrections

Both bot_instructions from 2026-05-15 (audit OCR / re-OCR Principality docs)
were auto-rejected by the U33 data-lane-router HTTP 400 bug (fixed in U75, but
these rows had already gone in before that fix landed).

Picked up tonight via "boxbot for next sprint instructions" review.

## Cross-check: Jo's expected loan refs vs database state

| ref | Jo's spec (bi#60) | DB state after corrections |
|---|---|---|
| 295905-02 | ARE ACTIVE £180,204 @ 2024-Q4 | ARE ACTIVE £224,655 @ 2025-Q4 ✓ (data is newer than Jo's email) |
| 967003-10 | Personal ACTIVE ~£274k @ 2024-Q1 | Personal ACTIVE £225,609 @ 2025-Q1 ✓ (paid down £49k over year) |
| 284512-03 | Mr J interest-only, £201,058 static, confirm status | Personal CLOSED 2024-01-01, balance frozen £201,058.22 since 2018 ✓ |
| 289759-10 | Mr J last 2021 £63,010, likely closed | Personal CLOSED 2024-01-01, last £55,100 @ 2023-Q3 ✓ |
| 289751-04 | Mr J last 2021 £167,800, likely closed | Personal CLOSED 2024-01-01, last £146,667 @ 2023-Q3 ✓ |
| 295178-07 | **Mr J + Mrs S** CLOSED 2021-09-30 £0 | **Family** (joint Mr J + Mrs S), CLOSED 2021-09-30 £0 ✓ |

## Corrections applied (this batch)

1. **289751-04** — closed_date 2022-01-01 → **2024-01-01**, current_balance £186,565 (Q4 2019) → **£146,667 @ 2023-Q3** (loan paid down longer than my placeholder assumed).
2. **289759-10** — closed_date 2022-01-01 → **2024-01-01**, current_balance £63k (Q3 2021) → **£55,100 @ 2023-Q3**.
3. **284512-03** — closed_date 2022-01-01 → **2024-01-01**, balance_as_of 2021 → 2023-Q3. Interest-only, balance flat at £201,058 the entire time.
4. **295178-07** — borrower_entity 3 (Personal) → **4 (Family)** per Jo's "Mr J + Mrs S Sandercock" joint borrower. closed_date 2022-01-01 placeholder → **2021-09-30** per Jo.

## Extras Jo's email didn't mention but are in the data

- **967002-01** (1 Castle Road active, £225,347 @ 2025-Q1) — distinct from 967003-10 per Jo's chat clarification "967002 = Castle Rd; 967003 = Salutations".
- **219125304** — appears in Jo's chat ("has been repaid"). No scans on file.

## Net worth unchanged

Closures don't affect current_balance for active loans, so the £1,485,147 net worth is unaffected by these corrections. The /finance Mortgages tab now shows the right closure dates + the joint borrower for the pub loan.

## Status

bi#59 + bi#60 marked `done` in bot_instructions with resolution noting
"addressed by U78 forensic rebuild + U93 closure-date fixes 2026-05-15".
