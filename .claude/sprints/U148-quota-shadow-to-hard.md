# U148 — Quota: shadow → hard mode

**Prereqs**: U143/U144 shipped (quota infrastructure live). 7+ days of shadow data accumulated.

**Realm**: `work` (operational AI hardening — see realm pivot 2026-05-19).

**Remote vs in-person**: 100% remote.

**Why this sprint exists**: Quota enforcement is fully built but running in **shadow** mode — it logs would-block events but doesn't actually block calls. Until flipped to hard mode, the £3/day API budget cap (per `feedback_budget_split`) is advisory only. Real cost protection requires hard enforcement.

## Tracks

### T1 — Shadow data audit (~30 min)

**Build**:
- Query last 7d of `ai_usage`: total cost per tier (P0/P1/P2/P3), per day.
- Cross-reference with `quota_allocations` ceilings. Identify days where any tier would have been blocked.
- Identify highest-cost capability_tags so we can verify the right calls are being attributed correctly.

```sql
SELECT date_trunc('day', created_at) AS day,
       business_priority AS tier,
       SUM(cost_gbp) AS spent_gbp,
       COUNT(*) AS calls
FROM ai_usage
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY 1, 2 ORDER BY 1 DESC, 2;
```

**Output**: `.claude/audits/u148-shadow-7d.md` with would-block counts per tier + recommendation on whether ceilings need adjusting.

**Acceptance**: report committed.

### T2 — Tune ceilings if needed (~30 min)

**Build**: if any tier consistently exceeded its shadow ceiling by >50%, revise the ceiling upward (write `V180__u148_quota_ceiling_revisions.sql`). Document why in commit message.

**Acceptance**: ceilings reflect realistic operational load.

### T3 — Flip enforce_mode hard, P3 first (~5 min — **PAUSE FOR JO'S GO**)

**Build**:
```sql
UPDATE quota_allocations SET enforce_mode='hard'
WHERE business_priority='P3';
```

P3 = lowest priority (background tasks). Safest first flip. Watch for 24h.

### T4 — Cascade P2 → P1 → P0 over 4 days (one tier per day)

**Build**: same flip per tier, watching `PromQL` alert `QuotaWouldBlock` and Telegram for any P0/P1 floor warnings.

**Hard-stop criteria**: if any flip causes >5 legitimate calls to be blocked in 24h, revert that tier and investigate.

### T5 — Telegram P0 floor alert (~30 min)

**Build**: new Prometheus alert `P0FloorRunningLow` (already wired in U143 monitoring) routes to Alertmanager → Telegram via `homeai-alertmanager` Slack webhook → tg_send bridge. Threshold: P0 daily floor remaining < 20% of allocation.

**Acceptance**: synthetic alert delivers to Jo's chat within 60s.

## Done criteria

- All 4 tiers in `enforce_mode='hard'`.
- No legitimate calls blocked in 7 days of post-flip soak.
- P0 floor alert fires once on a synthetic test.

## Risk

Medium. Wrong ceiling = legitimate calls blocked. Mitigations: 7d shadow audit; P3 first; one tier per day; revert-easy (single UPDATE).
