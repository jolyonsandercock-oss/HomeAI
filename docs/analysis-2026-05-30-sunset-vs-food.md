# Sunset Time × Pub Food Sales — Correlation Analysis

**Date:** 2026-05-30
**Pub:** The Olde Malthouse Inn (site=`malthouse`)
**Date range:** 2025-08-03 → 2026-05-29 (255 days where both sunset + food data are present)
**Requested by:** Hermes (review_1780100850.md)
**Verified by:** Claude (this analysis)

---

## TL;DR

Sunset time and pub food sales are **strongly correlated overall** (Pearson **r = 0.62**), but this almost entirely reflects shared seasonality, not a causal link.

After controlling for month-of-year, the within-month partial correlation drops to **r = 0.13** — small. The naïve correlation is a spurious artefact of late-summer (long days + tourism peak) vs winter (short days + low season) both moving together.

**Bottom line:** later sunset doesn't *cause* people to order more food; it's just that summer (the underlying driver) brings both at once.

---

## Tables used

| Table | Columns used | Why |
|---|---|---|
| `touchoffice_department_sales` | `report_date`, `department`, `value`, `site` | Daily £ totals per department per pub |
| `weather_daily` | `observation_date`, `sunset`, `rain_mm`, `peak_temp_c` | Sunset as `timestamptz`, plus weather confounders |

Department filter: `department = 'FOOD SALES'` (the canonical TouchOffice label — `'Food'` etc. don't match anything).
Site filter: `site = 'malthouse'` (the pub; café is `'sandwich'`).

## Methodology

1. Daily food £ per day = `SUM(value) FILTER (WHERE department='FOOD SALES')`.
2. Sunset → minutes past midnight = `EXTRACT(EPOCH FROM (sunset - date_trunc('day', sunset))) / 60`.
3. Pearson correlation overall, then sliced by weekday vs weekend, dry days only, and against temperature.
4. **Confounder control:** detrend both variables by subtracting their per-month mean, then re-correlate the residuals (within-month partial correlation).

## Results

| Slice | n | Pearson r |
|---|---:|---:|
| All days (naïve) | 255 | **0.6189** |
| Weekdays (Mon–Thu) | 145 | 0.6022 |
| Fri / Sat / Sun | 110 | 0.6569 |
| Dry days (rain < 1 mm) | 197 | 0.5506 |
| Temperature vs food (comparison) | 255 | 0.5925 |
| **Within-month residuals** | **255** | **0.1301** |

Mean food day: £1,079 ± £745 (sd).

### Monthly breakdown

| Month | n | Avg food £ | Avg sunset (UTC hr) |
|---:|---:|---:|---:|
| 1 (Jan) | 3 | 854 | 17:25 |
| 2 (Feb) | 21 | 516 | 18:37 |
| 3 (Mar) | 30 | 614 | 19:25 |
| 4 (Apr) | 30 | 1,151 | 20:14 |
| 5 (May) | 27 | 1,440 | 20:58 |
| 8 (Aug) | 29 | **2,375** | 20:34 |
| 9 (Sep) | 30 | 1,528 | 19:32 |
| 10 (Oct) | 31 | 1,015 | 18:25 |
| 11 (Nov) | 25 | 397 | 17:36 |
| 12 (Dec) | 29 | 476 | 17:17 |

Aug peak food (£2,375) and Aug late sunset (20:34) both reflect peak holiday season at a Cornish coastal pub. November dim sunset (17:36) and low food (£397) both reflect off-season closure of the trade.

## Interpretation

The 0.62 naïve correlation looks impressive but is dominated by seasonality — sunset and food sales are both seasonal variables, and seasonality at a coastal-tourist pub is a massive signal. Once you remove the month-level effect, sunset adds almost nothing predictive (r = 0.13 within-month).

Temperature shows the same pattern (r = 0.59 overall) — both sunset and temperature are stand-ins for "summer".

The slight residual within-month effect (r ≈ 0.13) could be:
- A real but small "long evenings → diners stay later → more food orders" effect
- Or noise (with n=255 and signed values, even r = 0.13 is borderline-detectable; the 95% CI is roughly ±0.12)

## Caveats & limitations

- **Months 6 + 7 missing** from the date range — touchoffice data only goes back to 2025-08-03, so we don't have June or July (the actual mid-summer peak). This understates the seasonal swing.
- **Sunset stored in UTC**, not BST — for visual display you'd subtract an hour during BST months, but it doesn't affect the correlation (the offset is constant).
- **Single pub** — can't compare across locations. Café (`sandwich`) wasn't included; its trade pattern is different (more daytime).
- **No control for special events / bookings / weather warnings** — a single big wedding or storm day can move the daily total a lot.

## Suggested follow-ups

1. **Re-run after capturing months 6 + 7** (when 2026's summer data lands). Will sharpen or weaken the seasonal effect.
2. **Hour-band correlation:** instead of daily totals, look at sales by hour-band vs hours-of-daylight. If "long evening → more dinner orders" is real, the dinner-hour band should correlate within-month more than the lunch band.
3. **Weekend × month interaction:** does Friday/Saturday show a stronger within-month sunset effect than weekdays? Worth checking separately.
4. **Multi-source baseline:** weather, sunset, rooms booked, tide times — fit a small multivariate model rather than testing pairs.

## SQL used

Saved at `/home_ai/postgres/queries/sunset-vs-food-correlation.sql` (companion to this doc).
