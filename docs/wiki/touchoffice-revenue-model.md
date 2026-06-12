# TouchOffice data model — why head_office is the revenue truth

TouchOffice (iCRTouch) serves three "sites" via the dashboard's site selector:
`1=malthouse` (pub till), `2=sandwich` (cafe till), `0=head_office`
(consolidated). We scrape daily widgets (FIXED TOTALS, DEPARTMENT SALES, PLU)
per site into `touchoffice_fixed_totals` / `touchoffice_department_sales` /
`touchoffice_plu_sales`, upserting on (site, report_date, key) — re-scrapes
replace, never duplicate.

**Revenue = head_office department-sales sum, nothing else.** The per-till
feeds are structurally unusable for revenue: malthouse "NET sales" already
CONTAINS the ACCOM department (adding caterbook accom on top double-counted
~£30k/month), and the per-till department tables carry a phantom ALCOHOL/DRINK
split plus cross-classified items that head-office reclassifies (sandwich till
May-2026: £37,374 vs true cafe £33,142). head_office collapses all of that into
the consolidated lines Jo's reports use — reconciled to the penny for
Mar/Apr/May-2026 (V265 asserts those figures).

`v_daily_unit_economics.total_revenue` uses head_office with a per-till
fallback ONLY where no head_office row exists; the `revenue_source` column
('head_office' | 'per_till_legacy') tells you which basis a day is on — check
it before trusting a number. Labour% divides on-costed labour by this revenue
(matches Workforce's Wage% — May-2026: 29.3% vs report 29.33%).

Freshness/self-heal: the daily 03:30 scrape covers all three sites; nightly
`u274` re-attempts any date with no head_office rows. A SUCCESSFUL scrape that
writes 0 rows is terminal — it means the pub wasn't trading (Jan-2026: closed
5th–31st; 4 trading days, £7,925 — real closure, not a gap). Per-till data
remains useful for per-site labour attribution and PLU-level analysis only.

Related: workforce on-cost model (award_cost × era multiplier), caterbook
accommodation (room-night grain).
