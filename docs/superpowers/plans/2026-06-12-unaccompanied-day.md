# Unaccompanied Work Day — 2026-06-12

> Autonomy plan agreed with Jo 2026-06-11 evening. Each block is independently
> shippable with its own verification gate. Anything blocked: log it, Telegram
> a one-liner, move to the next block — no rabbit holes (3-attempt rule).

## Hard rules (non-negotiable)
- **No guest-facing sends.** Outbound email only to Jo (jolyboxbot@ → jolyon.sandercock@gmail.com). Breakfast/dinner work produces DRAFTS only.
- **Read-only on external systems.** Caterbook PMS scrape = navigation + reads. No clicks that mutate (no booking edits, no settings).
- **No resolver mode changes** (stays review-for-invoices, shadow-for-bank).
- **Compute-and-assert** on every data write; audit_log rows for bulk changes; additive migrations only.
- **No realm/entity flips** without named evidence (the #8/#9/#24 snags stay open for Jo).
- Telegram checkpoints: morning start, midday status, end-of-day summary.

## Block 0 — Morning verification sweep (~30 min)
1. Overnight u274 backfill: confirm Jan-2026 revenue gap healed; report pre-2026
   head_office coverage (how far back TouchOffice actually serves).
   Gate: `v_daily_unit_economics` Jan-2026 days with revenue_source='head_office' > 25.
2. selftest.sh green (incl. [10] revenue + on-cost anchors); invariant gate clean;
   u272 watchdog log quiet; review-scrape + weather crons produced fresh rows.
3. Snag inbox: triage any new submissions (V267: closures need notes).

## Block 1 — Caterbook PMS guest-record scrape (task #12, ~half day)
Goal: authoritative guest **email + phone** per reservation → accommodation_bookings.
1. Recon: log into Caterbook PMS (creds `secret/caterbook`) via homeai-playwright;
   snapshot the reservation-detail DOM; identify guest-contact fields.
2. Scraper `services/playwright/scrapers/caterbook_guests.py`: iterate reservations
   with checkin ≥ today-30 (forward-relevant first), extract email/phone,
   UPSERT into accommodation_bookings (fill NULLs only, never overwrite).
3. Gate: cross-check ≥20 scraped phones against the 310 ref-join-backfilled ones —
   mismatch rate must be ~0 before writing emails at scale.
4. Add nightly cron (after the 03:00 scrape window) + freshness via data_freshness.
5. Stretch: propagation trigger caterbook_bookings.contact → accommodation_bookings.

## Block 2 — Vision-OCR production fallback (task #8, ~half day)
Goal: stuck invoices get amounts, safely.
1. `scripts/u281-vision-ocr-drain.py`: for pdf_low_conf invoices with a local PDF
   and no text: render pages (back-to-front), qwen2.5vl:7b extract,
   **ACCEPT only if |net+vat−gross| ≤ 0.02** (the gate that catches every
   benchmark failure mode); write net/vat/gross + extraction_method='vision_ocr',
   extraction_confidence=0.7; leave rejects untouched for the W7800 32B re-pass.
2. Drain the 82 local-PDF backlog; report accept/reject split.
3. Wire the same function as a 30-min cron over NEW pdf_low_conf arrivals.
4. Gate: spot-check 10 accepted extractions against page images (manual eyeball
   of rendered PNGs); zero arithmetic-invalid rows written.
5. Stretch: PDF-fetch the ~1,180 stuck invoices WITHOUT local PDFs (gmail
   attachment fetch path exists — `pdf_fetch` fields) then drain those too.

## Block 3 — Breakfast & dinner pre-arrival DRAFTS (snags #39/#40)
Depends on Block 1 raising email coverage. DRAFT-ONLY regardless.
1. Recover the old breakfast workflow (Jo: "we had a breakfast workflow — look
   for this") — check n8n workflow_entity + scripts/u106/u160 for the template.
2. `u282-prearrival-drafts.py`: guests arriving in 2 days with an email →
   render breakfast-order + dinner-booking emails using the u106/u160 templates;
   write to a drafts table + Gmail Drafts folder (google-fetch /draft endpoint);
   daily summary email TO JO listing drafts ready to approve.
3. Rooms page: "Breakfast forecast"/"Dinner bookings" sections get draft counts.
4. Gate: zero sends to non-Jo addresses (grep the script: only /draft endpoints).

## Block 4 — Bank-side resolver groundwork (shadow only)
1. Mine recurring bank narrative stems (DDs/SOs ≥3 occurrences, exact-stem match)
   → candidate `bank_reference` anchors with proposed counterparty (domain-matched
   via invoice vendor names where unambiguous).
2. Write candidates to a report (NOT to counterparty_anchor) — email Jo the top 50
   for one-pass approval. No attribution writes.

## Block 5 — End-of-day
- Full selftest + invariant gate + commit/push (re-anchor baseline if compose moved).
- Memory updates for anything non-obvious discovered.
- End-of-day Telegram + email summary: shipped / blocked / decisions needed.

## Parked for Jo (do NOT attempt unaccompanied)
- Management-email variant choice (A/B/C) → then wire daily cron.
- Snags #8/#9/#24 (need re-snag/evidence), #60 COGS (needs restating), #72/#73 re-snag.
- W7800 install day (ROCm migration checklist in HOME-AI-STRETCH §3.9).
- U151b superuser-DSN migration (needs attended rollout window).
- Publishing this week's Tanda rota (operational).
