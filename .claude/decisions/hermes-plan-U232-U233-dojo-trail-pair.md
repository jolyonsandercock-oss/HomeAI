# Plan for Hermes — capture Dojo + Trail DOM during Jo's pair runs

Drop this file (or its content) into Hermes via `/home_ai/scripts/hermes-reply.sh u232-u233-dojo-trail-pair-plan < this-file` once the outbox is set up.

---

## Why

Claude has written the Dojo (U232) and Trail (U233) scrapers — login + email-2FA + "remember device" are wired and tested as far as Auth0's MFA screen. What remains is the **table extractors** (`scrape()` body) which need real DOM selectors from the production dashboards. Claude can't run a headed browser blind, so we need DOM snapshots from Jo's pair sessions.

## What Claude needs from each pair run

For **both Dojo and Trail**, after Jo signs in successfully and navigates to the data table:

1. **Page URL** — the full URL of the page that contains the list/table we want to scrape.
2. **One row of the table's outerHTML** — right-click the row → Inspect → "Copy → Copy outerHTML". One row is enough; classes + nested structure are what matter, not values.
3. **The table header row's outerHTML** — same procedure on the `<tr>` containing column labels.
4. **Date range UI** — if the page has a date picker / range selector, screenshot it + paste the input element's outerHTML.
5. **Pagination clue** — does the table paginate? If so, paste the pagination control's HTML or describe it ("Load more button" / "page 1 of 12" / "infinite scroll").

That's it. No values, no credentials, no live data — just the DOM scaffolding.

## Where Hermes fits

Two options Hermes can take:

### Option A — passive coach
Wait for Jo to do the pair, then review what Jo posts back and:
- Check it's enough for Claude to write selectors (often the case)
- Flag if anything's clearly wrong/missing
- Optionally suggest Playwright locator strategies (`page.locator('table.transactions tr:not(:first-child)')` etc.)

### Option B — pre-flight reconnaissance
Hermes already has browser tools on the laptop. Hermes could open the Dojo + Trail dashboards itself (Jo signs in via the GUI), capture the same DOM artefacts pre-emptively, and drop them into the dropbox — saving Jo the inspect-element ceremony.

Recommended: **B if Hermes's stack supports it**; **A otherwise**.

## Drop format

Whichever option, drop one file per scraper in the standard Hermes pipeline:

```
review_<timestamp>_dojo-dom.md
review_<timestamp>_trail-dom.md
```

Body shape:

```markdown
## Dojo transactions list — DOM snapshot

URL: https://account.dojo.tech/payments/transactions

### Header row
\`\`\`html
<tr class="...">
  <th>Date</th>
  <th>Amount</th>
  ...
</tr>
\`\`\`

### Sample row
\`\`\`html
<tr class="...">
  <td>...</td>
  ...
</tr>
\`\`\`

### Pagination
"Load 50 more" button: <button class="...">Load more</button>

### Date range
<input type="date" name="from" /> <input type="date" name="to" />
```

Claude will read this, write the `scrape()` extractor against the real DOM, rebuild the playwright image, and confirm via headless run.

## Constraints (4-eyes guardrails)

- **No values.** Strip transaction amounts, card numbers, customer names, dates with actual data. Replace with placeholders if you're nervous.
- **No cookies / tokens.** Don't paste session cookies, JWTs, CSRF tokens — Claude doesn't need them.
- **No screenshots of the data table** unless values are redacted. Screenshots of empty headers or date pickers are fine.

## Once Claude has the DOM

Estimated build cycle per scraper:
- 30 min: write the extractor with the captured DOM
- 5 min: rebuild + recreate `homeai-playwright`
- 5 min: headless test via `curl -X POST http://homeai-playwright:8001/scrape/dojo` (or /trail)
- 5 min: wire daily cron + decommission old script
- 10 min: 24h soak, verify `dojo_transactions` / `trail_reports` is fresh

So total per scraper: ~1 hour after DOM lands. Both can finish in a single session.
