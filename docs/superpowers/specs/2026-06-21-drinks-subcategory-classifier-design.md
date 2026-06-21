# Drinks sub-category classifier (beer / wine / spirits / minerals) — design

**Date:** 2026-06-21 · **Status:** approved → build

## Problem
Line-item descriptions exist (`vendor_invoice_lines`) but have no drinks sub-category, so
"beer / wine / spirits / minerals" spend can only be guessed by keyword at query time — which
mis-classifies cooking wine, wine vinegar, and "Ale Chutney" as bar drinks, and can't find
brand-named wine (Hardys, Campo Viejo) at all. We want exact drinks spend by category.

## Design — deterministic, post-extraction classifier
A separate rules-driven classifier, NOT a change to `invoice-line-extract.py` (that file is
owned by the concurrent session, is LLM-driven, and would only touch newly-extracted lines).
This mirrors the existing `vendor_category_rules` + categorise-sweep pattern: deterministic
regex rules, **unmatched left NULL and surfaced for rule-adding — never guessed.** Backfills all
~4,400 existing lines plus future ones.

## Data model (migration)
- `vendor_invoice_lines.drinks_subcategory text` — `beer | wine | spirits | minerals | other | NULL`.
  `other` = matched a drinks keyword but is **not** bar-drinks spend (cooking wine, wine vinegar,
  ale chutney) — kept distinct so it's excluded from spend without being re-matched each run.
  CHECK constraint allows those 5 values or NULL.
- `drinks_category_rules(id, pattern text, subcategory text, priority int default 100, notes,
  active bool default true, realm text default 'work', created_at)` — regex (POSIX `~*`) →
  subcategory. Lower `priority` wins; **exclusion rules use priority 1** (so `vinegar` beats the
  `\bwine\b` wine rule). Same realm column + `realm_isolation` RLS as `vendor_category_rules`.

## Classification (one sweep: `scripts/u-drinks-classify-sweep.sh`, cron-able)
```sql
UPDATE vendor_invoice_lines l
SET drinks_subcategory = (
  SELECT r.subcategory FROM drinks_category_rules r
  WHERE r.active AND l.description ~* r.pattern
  ORDER BY r.priority ASC, length(r.pattern) DESC LIMIT 1)
WHERE l.drinks_subcategory IS NULL
  AND EXISTS (SELECT 1 FROM drinks_category_rules r WHERE r.active AND l.description ~* r.pattern);
```
Idempotent (only fills NULLs). Records a heartbeat via `ops.record_pipeline_run('drinks_classify',…)`.
Logs the top unmatched-by-£ drinks-supplier lines (St Austell etc.) so new rules can be added —
surface-don't-guess.

## Seed rules
- **priority 1 (exclusions → `other`)**: `vinegar`, `cooking wine`, `ale chutney`, `wine gum`, `beer batter`.
- **beer (100)**: `\d+ ?ltr`, `\bkeg\b`, `\bcask\b`, `lager`, `\bipa\b`, `\bstout\b`, `\bcider\b`,
  `\bbitter\b`, `pilsner`, `helles`, `korev`, `tribute`, `proper job`, `doom`, `harbour`, `madri`,
  `guinness`, `carling`, `heineken`, `peroni`, `cornish orchard`.
- **wine (100)**: `\bwine\b`, `\b(75cl|175ml|187ml|250ml)\b`, `prosecco`, `champagne`, `merlot`,
  `malbec`, `sauvignon`, `pinot`, `chardonnay`, `rioja`, `rosé|rose wine`, `hardys`, `campo viejo`.
- **spirits (100)**: `vodka`, `\bgin\b`, `whisky|whiskey`, `\brum\b`, `brandy`, `tequila`, `liqueur`,
  `bourbon`, `aperol`, `gordon|smirnoff|bacardi|jameson|jack daniel`.
- **minerals (100)**: `\bcoke\b|coca.?cola`, `pepsi`, `lemonade`, `\btonic\b`, `\bjuice\b`,
  `squash`, `post.?mix`, `\bsoda\b`, `still water|sparkling water|mineral water`, `\bj2o\b`,
  `fanta|sprite|appletiser|fruit shoot`, `red bull|monster`.

## Output
`CREATE VIEW v_drinks_spend` — per month × subcategory: `sum(line_net)`, line count, distinct
invoices. Filters to `drinks_subcategory IN ('beer','wine','spirits','minerals')` (excludes `other`).

## Testing
- Migration test: column + table + view + CHECK exist; seed rule count > 0.
- Classifier test (transaction-rollback fixtures): "50LTR KOREV 4.8%"→beer; "Campo Viejo Rioja
  750ml"→wine; "Smirnoff Vodka 70cl"→spirits; "Coca-Cola post-mix"→minerals; "White Wine
  Vinegar"→other (NOT wine); "Hogs Jail Ale Chutney"→other.
- Live: run sweep, confirm June beer = the St Austell kegs, wine now finds bottles, vinegar excluded.

## Out of scope (YAGNI)
- No LLM. No change to the extractor. No auto-applied rules beyond the deterministic seed (new
  rules are human-added, surfaced by the sweep). Metis-tracking is a later enhancement.
