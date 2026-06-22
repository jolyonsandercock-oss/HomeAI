# 2026 YTD Reassessment — Finding (as at 2026-06-19)

Read-only recon, all 4 entities, 2026-01-01 → 2026-06-19. Sources: v_daily_cost_vs_sales
(trading), invoices+vendor_invoice_lines (costs), v_rental_income (property),
raw.bank_lines (banking). Methodology: deduped (invoice idempotency_key; bank row_hash),
entity-aware, cross-footed per the ATR recon discipline.

## Reliable
- **ARTL (entity 1, trading) revenue: £413,338** (152 days); derived COGS £132,121 (~32%); accom £86,968.
- **Captured supplier invoices (deduped):** ARTL £76,580 (140) · ARE £108 · Personal £8,857 · Family £0.
- **Property:** ~£9,064/mo expected rent vs £20,364/mo mortgages → portfolio cash-negative on financing.

## Two data-integrity issues (numbers NOT trustworthy until fixed)
1. **Invoice capture incomplete (~42% gap).** ARTL captured invoices £76,580 = only ~58% of
   the £132,121 derived cost-of-sales. Root cause: 183 of 232 failed invoice.detected events
   had NO PDF attachment (HTML/inline/linked invoices) — the PDF-vision pipeline can't ingest them.
   FIX: build an email-body (HTML/text) invoice ingestion path. → cost gap closes.
2. **Bank: entity-mapping is CORRECT; the real gap is an under-imported trading current.**
   - CORRECTION: canonical bank ledger is **`public.bank_transactions`** (22,476 rows, idempotency_key
     fully distinct), NOT `raw.bank_lines` (incomplete staging — gave a false "6 txns / mis-mapped"
     reading). `bank_accounts` maps accounts→entities correctly (600001-36345245 = Jo personal, etc.).
   - From the correct source, ARTL has **479** YTD txns (Cap On Tap 240 + Dojo settlement 48885517 228 +
     main trading current 17065488 only **7** + reserve 4); net **−£40,439**, inflow £186,670.
   - CORRECTION (checked 2026-06-19): 17065488 is a LOW-ACTIVITY/dormant account (1-2 txns/mo, ~£3-4k
     overdrawn, monthly interest; 82 txns over 6 yrs) — correctly/fully imported, NOT under-imported.
     Active ATR banking = Dojo settlement 48885517 (228 YTD) + Cap On Tap (240) — both imported.
   - Residual: bank inflows (£187k) trail trading revenue (£413k) — this is a CARD-SETTLEMENT
     reconciliation matter (Dojo nets fees + sweeps), not a missing statement.
   FIX: a proper card-settlement→bank cash reconciliation (Dojo/Clover → settlement account), not a re-import.

### Card-settlement reconciliation (done 2026-06-19) — the real bank gap
- Revenue £413,338 = **card £330,832** (Dojo authorised £318,654 + Clover £12,178, ~80%) + **cash ~£82,506** (~20%).
- Dojo settlements actually in the bank ledger (acct 48885517) = only **~£124,591**.
- → **~£194k of card settlements are MISSING from the bank** — the **Dojo settlement account 48885517 is
  under-imported for 2026** (NOT 17065488, which is dormant). This is the whole revenue-vs-bank-inflow gap.
- FIX for an accurate bank net position: import the full 2026 statements for acct **48885517** (Dojo
  settlement). After that, ARTL bank inflows should reconcile to card (net of ~1.75% fees) + cash deposits.

## Non-PDF email-body ingestion (built 2026-06-19)
Built + ran (`scripts/backlog-emailbody-extract.js`): of the 183 no-PDF events, only **3 real inline
invoices recovered (£250.13)**. The rest: 103 correctly rejected (statements/notifications/marketing/
payment-received), 76 no extractable body (mostly PORTAL-LINK invoices — data not in email text).
Conclusion: the invoice-capture gap is **structural** (COGS includes wages/utilities-by-DD + link-based
invoices), NOT closable by email-body extraction. Committed source='email_body', idempotent.

## Bottom line
Revenue YTD is solid (£413k ARTL). Cost + net-position are NOT reliable until (1) non-PDF invoice
ingestion and (2) bank account→entity remapping + full import are done. Recon surfaced these
rather than presenting a falsely-precise net figure.
