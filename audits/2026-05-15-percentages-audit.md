# Percentages audit (labour %, GP %, occupancy %)

Generated 2026-05-15. Read-only audit against `pg_get_viewdef`.

## TL;DR

- ✅ **labour_pct** — formula correct: `labour_cost_est / (pub_net_sales + sandwich_net_sales) * 100`. Current value 77.8% on 2026-05-15 is anomalous (target <30%) — flagged as likely a real ops issue or data lag rather than formula error.
- 🔴 **pub_drink_gp_pct / pub_food_gp_pct** — **HARDCODED 60/40 wet/dry split**. `pub_net_sales * 0.60` is used as wet revenue, irrespective of actual department mix. This makes the per-stream GP% wrong on any day the real mix isn't 60/40.
- ✅ **cafe_gp_pct** — `(sandwich_net_sales − cafe_cost) / sandwich_net_sales`. Uses actual sandwich sales as denominator. Correct.
- ✅ **occupancy_pct** — `occupied_rooms / total_rooms * 100`. Correct. Total rooms pulled from `ops_constants.inn_total_rooms`.
- ⚠ **labour_pct_light** thresholds — green/amber/red sourced from `ops_thresholds` table. Worth verifying values match operations intent.

## Findings detail

### 🔴 pub GP% uses hardcoded 60/40 split (HIGH PRIORITY)

`v_daily_gp.pub_drink_gp_pct` formula:

```sql
CASE WHEN pub_net_sales > 0 THEN
    round(100 * (pub_net_sales * 0.60 - wet_cost) / NULLIF(pub_net_sales * 0.60, 0), 1)
ELSE NULL END
```

`pub_food_gp_pct` does the same with `* 0.40`.

**Why this is wrong**: actual wet/dry split varies day-to-day. On a heavy-food
Sunday roast day it might be 35/65; on a beer-garden Saturday it's 75/25.
Using a hardcoded 60/40 silently biases every per-stream GP%.

**Correct source**: `touchoffice_department_sales` already breaks per-day
sales into named departments. Aggregate "wet" departments (Alcohol Sales,
Wines, Spirits, Soft Drinks) vs "dry" (Food Sales, Hot Drinks) vs the
sandwich/cafe stream.

**Fix outline**:

```sql
-- New CTE in v_daily_gp:
WITH dept_sales AS (
    SELECT report_date, site,
           sum(value) FILTER (WHERE department IN ('ALCOHOL SALES','WINES','SPIRITS','SOFT DRINKS')) AS wet_net,
           sum(value) FILTER (WHERE department IN ('FOOD SALES','HOT DRINKS')) AS dry_net
      FROM touchoffice_department_sales
     GROUP BY report_date, site
)
```

Then `pub_drink_gp_pct = (wet_net - wet_cost) / wet_net * 100`.

Same shape for `pub_food_gp_pct`.

### ✅ labour_pct correct, but value is anomalous today

Formula (in `v_daily_unit_economics`):
```sql
labour_cost_est / (pub_net_sales + sandwich_net_sales) * 100
```

Value today: **77.8%** vs target **<30%**.

Sales £4,450 → implies labour cost £3,462. Plausible for a heavy shift
(11 staff Tikes/Freja/etc.) but worth a Telegram alert if the data is real.

`pub_labour_pct` and `cafe_labour_pct` (split per-site) exist too —
use those for the more accurate per-site view rather than the blended
`labour_pct`.

### ✅ occupancy_pct correct

```sql
occupied_rooms = count(distinct room) from caterbook_daily_snapshots arrivals + stayovers
total_rooms = ops_constants.inn_total_rooms
occupancy_pct = occupied_rooms / total_rooms * 100
```

Sourced from real Caterbook data. No issue.

### ⚠ Threshold values (green/amber/red)

```sql
labour_pct_light:
    < green_max  → green
    <= amber_max → amber
    > amber_max  → red
```

`green_max` + `amber_max` live in `ops_thresholds` table. Worth a quick check Jo's
intent matches the stored values — sample:

```sql
SELECT metric, green_max, amber_max FROM ops_thresholds;
```

## Per-stream sources crossed-checked

| dashboard tile | source view | source columns | scoping | verdict |
|---|---|---|---|---|
| /m Labour % | v_live_ops_kpis | labour_cost_est / (pub_net_sales + sandwich_net_sales) | today only | ✓ correct |
| /m Takings | v_live_ops_kpis | total_net_sales | today only | ✓ correct |
| /economics GP daily | v_daily_gp.overall_gp_pct | total_revenue minus all costs | per-day | ✓ correct (aggregate level) |
| /economics GP pub-drink | v_daily_gp.pub_drink_gp_pct | hardcoded 60% slice | per-day | 🔴 wrong — see above |
| /economics GP pub-food | v_daily_gp.pub_food_gp_pct | hardcoded 40% slice | per-day | 🔴 wrong — see above |
| /economics GP cafe | v_daily_gp.cafe_gp_pct | sandwich_net_sales − cafe_cost | per-day | ✓ correct |
| /pub occupancy | v_live_ops_kpis.occupancy_pct | caterbook + ops_constants | today only | ✓ correct |

## Recommended next sprint

**U93 T1**: Replace hardcoded 60/40 in `v_daily_gp` with actual department-mix
pull from `touchoffice_department_sales`. Migration `V100__fix-pub-gp-actual-mix.sql`.

**U93 T2**: Confirm `ops_thresholds` values match Jo's current operational
targets (labour <30%? GP >65%? Anomaly thresholds?).
