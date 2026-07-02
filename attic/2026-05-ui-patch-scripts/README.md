# Attic: 2026-05 UI patch scripts

These are ~44 one-shot patcher scripts that were run from the repo root
during May-June 2026 to make targeted, hand-crafted edits to the
frontend (`services/homeai-frontend/app/**/page.tsx`) and a handful of
one-off backend/SQL fixes. Each script hard-codes a source or target
file path and either does a literal string/byte replacement, a
line-number-based rewrite, or (for a few) runs a one-time SQL migration
or a manual slug-verification check via `docker exec` / `urllib`.

They were run once, their edits landed in the target files (which are
the durable artifacts — these scripts are not), and they are not
imported or invoked by any other script, cron job, or service. They
were left in the repo root as incidental history rather than by
design.

Moved here as part of the R5 hygiene sweep (2026-07-02) to declutter
the repo root. Kept (not deleted) for archaeology — if a future change
to sales/tasks/comms/backend/dashboard pages needs to understand how a
past UI feature was introduced, these scripts show the literal diff
that was applied at the time.

## Inventory

Frontend UI patchers (target `services/homeai-frontend/app/**/page.tsx`):

- add-bar-labels.py — value labels/percentages on category breakdown bars (sales)
- add-expense-exceptions.py — expense exceptions section (tasks)
- add-extract-button.py — force-extract button (admin/invoices/[id])
- add-pagination.py — sales table pagination + pollclock alignment fix
- add-pdf-status.py — PDF extraction status in line item modal (tasks)
- add-quota-to-backend.py — QuotaStatusTile on backend page
- add-realm-modal.py — editable Business area dropdown (tasks modal)
- add-site-filter.py — site filter + realm/business area (tasks)
- color-green.py / fix-green.py / green-labour.py — iterative attempts to
  fix labour % default colour to emerald green (sales)
- comms-email.py / email-modal.py — replace comms page email section with
  flagged-email table + keyword management / modal
- count-balance.py / diagnose-syntax.py / find-brace.py / find-unbalanced.py —
  diagnostic scripts used to locate a JSX brace/bracket imbalance bug
  in sales/comms pages (not patchers — read-only diagnosis)
- fix-bar-drinks.py — bar drink classification fix in slug SQL definitions
- fix-body-text.py / fix-body-v2.py — comms page placeholder body text fix
  (v2 superseded v1 in the same session)
- fix-booking.py — booking-scraper.py SQL/data cleanup (one-off)
- fix-tsx.py / fix-tsx-ambiguity.py — fix `>` operator ambiguity inside JSX
  expressions (sales page), two iterations
- fix-warning-text.py — "figures are for" dashboard warning text/date logic
- fix-yest.py — 'yest' -> 'yesterday' across department pages
- line-item-modal.py / modal-assign.py — tasks page expense-exception modal
  (line item detail, category assignment)
- move-expenses.py — move ExpenseRollup component from admin to backend page
- patch-chart-colors.py / patch-sales-chart.py — sales page chart colour and
  labour%-line/tab-filtering patches
- pipeline-final.py / pipeline-patch.py — backend page pipeline logs section
  (patch was a v2 exact-match iteration on final)
- priority-email.py — dashboard priority email view
- redesign-email.py / redesign-email-dashboard.py — dashboard email section
  redesign to keyword-grouped cards (two iterations)
- remove-quota-admin.py — remove QuotaStatusTile from admin page
- revert-line.py — revert 3-segment labour% chart line to single line
- rewrite-sales-table.py — split sales table into Pub/Cafe sections
- rewrite-tasks.py — tasks page rewrite (30d filterable/sortable action queue)
- rm-sparklines.py — remove SparkLine components from dashboard
- snag-frontend.py — snag inbox section on tasks page
- sortable-email.py / sortable-v2.py — sortable/filterable flagged-email
  table headers on comms page (two iterations)

Other one-offs:

- create-auto-rules.py — one-time SQL: auto-create vendor_category_rule
  from feedback + trigger + cron wiring
- verify-slugs.py — manual slug-output verification via localhost fetch,
  run once after a batch of the above fixes

None of these are imported by, or referenced from, any other script,
cron job, or service in the repo (verified via grep across
`scripts/`, `services/`, and top-level config during the R5 sweep).
