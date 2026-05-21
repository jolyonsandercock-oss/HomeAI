# U148 — Quota shadow audit (7d, ending 2026-05-21)

## Ceilings (current shadow)

| tier | daily £ | monthly equivalent | % of £3/day budget |
|---|---|---|---|
| P0 | 0.90 | 27.00 | 30% |
| P1 | 1.05 | 31.50 | 35% |
| P2 | 0.63 | 18.90 | 21% |
| P3 | 0.42 | 12.60 | 14% |
| **total** | **3.00** | **90.00** | 100% |

## Actual spend (7 days)

| day | tier | calls | spent £ | % of tier ceiling |
|---|---|---|---|---|
| 2026-05-21 | P1 | 5 | 0.004 | 0.4% |
| 2026-05-20 | P3 | 1 | 0.018 | 4.2% |
| 2026-05-19 | P0 | 4 | 0.004 | 0.4% |
| 2026-05-19 | P3 | 1 | 0.016 | 3.8% |
| 2026-05-18 | P0 | 2 | 0.047 | 5.2% |
| 2026-05-18 | P1 | 85 | 0.061 | 5.8% |
| 2026-05-18 | P3 | 1 | 0.014 | 3.4% |
| 2026-05-17 | P0 | 11 | 0.213 | 23.7% |
| 2026-05-17 | P1 | 2 | 0.001 | 0.1% |
| 2026-05-16 | P0 | 5 | 0.045 | 5.0% |
| 2026-05-16 | P1 | 10 | 0.008 | 0.8% |
| 2026-05-16 | P3 | 1 | 0.014 | 3.4% |
| 2026-05-15 | P3 | 1 | 0.010 | 2.4% |

**Peak single-day spend**: 2026-05-17 P0 = £0.213 (23.7% of P0 ceiling).
**No tier got within 50% of its ceiling on any day.**

## Would-block events

`SELECT COUNT(*) FROM ai_usage WHERE would_block_reason IS NOT NULL AND timestamp > NOW()-INTERVAL '7 days'` = **0**

In shadow mode, **zero calls would have been blocked**. Spend stays comfortably within budget.

## Recommendation: SAFE TO FLIP — single-step

Given:
- 0 would-block events in 7 days
- Peak utilization 23.7% on any tier on any day
- Total weekly spend £0.47 (vs £21 weekly budget = 2.2% utilization)

A staged tier-by-tier flip would gain no information (every tier has the same headroom). Recommend single-step:

```sql
UPDATE quota_allocations SET enforce_mode = true;
```

This makes hard-mode enforcement active for all tiers immediately. If any tier ever approaches its ceiling, the existing Prometheus alert `P0FloorRunningLow` (and similar per-tier) fires.

## Next steps (pending Jo's go)

- T3 — flip enforce_mode = true (one-line SQL above).
- T5 — verify P0 floor alert routes to Telegram (synthetic test).
- Monitor 7 days post-flip for any unexpected blocks.

## Status

- ✅ Shadow audit complete
- ⏸ Hard-mode flip **awaiting Jo's sign-off**
