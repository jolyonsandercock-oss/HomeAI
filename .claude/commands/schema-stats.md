---
name: schema-stats
description: Show cognition schema-fires telemetry — which schemas earn their keep
---
Run these queries against the `homeai` database (postgres user, host=172.19.0.5, password in vault `secret/postgres-roles/postgres` or `/home_ai/.env` POSTGRES_PASSWORD) and report concisely.

1. **Headline summary** (real session telemetry, last 14 days):
```sql
SELECT schema_name, fired, missed, hit_pct, age
  FROM cognition.v_schema_fire_stats
 WHERE consumer='session' AND last_seen >= NOW() - INTERVAL '14 days'
 ORDER BY fired DESC;
```

2. **Deletion candidates** (never fired in the window):
```sql
SELECT schema_name, examined, last_seen
  FROM cognition.v_schema_fire_stats
 WHERE consumer='session' AND fired = 0
   AND last_seen >= NOW() - INTERVAL '14 days';
```

3. **False-positive watch** (schemas firing on prompts that probably weren't the right shape — look for ones with hit_pct >50% on a small sample, suggests over-eager keywords):
```sql
SELECT schema_name, fired, missed, hit_pct
  FROM cognition.v_schema_fire_stats
 WHERE consumer='session' AND fired > 0
   AND last_seen >= NOW() - INTERVAL '14 days'
 ORDER BY hit_pct DESC;
```

4. **Total prompts in the window**:
```sql
SELECT COUNT(DISTINCT prompt_hash) AS unique_prompts,
       COUNT(*) AS schema_examinations
  FROM cognition.schema_fires
 WHERE consumer='session' AND ts >= NOW() - INTERVAL '14 days';
```

After running, present:
- Top 3 most-fired schemas
- Any deletion candidates (zero fires)
- Any false-positive concerns (hit_pct unusually high — likely an over-broad keyword)
- Total prompts and time window
- One-line recommendation for U220 curation if there's enough data (≥100 unique_prompts is a reasonable threshold)

If `cognition.v_schema_fire_stats` doesn't exist, suggest the user re-run the cognition-build orchestrator to recreate the schema.
