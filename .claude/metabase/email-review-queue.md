# Email Review Queue — Metabase card

Required for Gate B Q7 ("email visible in review queue").

## SQL (paste into Metabase Native query editor)

```sql
SELECT
  e.received_at,
  e.from_address,
  e.subject,
  e.classification,
  e.confidence_score,
  CASE
    WHEN e.requires_human THEN 'flagged'
    WHEN e.confidence_score < 0.75 THEN 'low confidence'
    WHEN NOT e.processed THEN 'pending'
    WHEN e.action_required THEN 'action required'
    ELSE 'review'
  END AS reason,
  ent.name AS entity,
  e.id AS email_id,
  e.gmail_message_id
FROM emails e
LEFT JOIN entities ent ON ent.id = e.entity_id
WHERE e.requires_human = TRUE
   OR e.confidence_score < 0.75
   OR NOT e.processed
   OR e.action_required = TRUE
ORDER BY e.received_at DESC NULLS LAST
LIMIT 50;
```

## Steps to create (~2 min in Metabase UI)

1. Browser → `http://100.104.82.53:3000` → log in.
2. Top-right **+ New** → **SQL query**.
3. Database dropdown → **homeai**.
4. Paste the SQL above.
5. Click **Run** (▶ icon) — should return rows (or empty if no test data).
6. **Save** → Name: `Email Review Queue` → Description: `Emails awaiting human review (low confidence, requires_human, action_required, or unprocessed)` → Save to → choose `Our analytics` collection → **Save**.
7. (Optional) From the saved card, click **Add to dashboard** → **+ Create new dashboard** → Name: `Email Operations` → save.

## What this satisfies

Gate B Q7 — "email visible in review queue". The card displays any email matching the review-needed criteria.

## After Master Router routing is fixed

Once the synthetic email test runs end-to-end, this card will display the synthetic test email. Real emails (post Gmail OAuth) appear automatically.
