# Proposal: PostgreSQL shared_buffers 16GB → 32GB
# Target: /home_ai/docker-compose.yml (or wherever homeai-postgres is defined)
# Authored: Hermes, 2026-06-11
# Priority: medium (performance improvement for analytics queries)

## Current state
- 128GB RAM host
- Postgres running in Docker container `homeai-postgres`
- shared_buffers = 16GB (good but conservative)
- effective_cache_size = 64GB (already well-tuned)
- random_page_cost = 1.1 (correct for NVMe)

## Change
Increase shared_buffers to 32GB. This is ~25% of 128GB — well within the PG
comfort zone for a dedicated DB that shares the box with Ollama (~5GB), n8n,
and other services.

## How to implement (option A: custom config bind-mount)
1. Create `/home_ai/postgres/custom-postgresql.conf` with:
   ```
   shared_buffers = 32GB
   ```
2. Mount it into the container in docker-compose.yml:
   ```
   volumes:
     - /home_ai/postgres/custom-postgresql.conf:/etc/postgresql/postgresql.conf.d/custom.conf:ro
   ```
3. `docker compose down homeai-postgres && docker compose up -d homeai-postgres`
4. Verify: `SHOW shared_buffers;`

## How to implement (option B: direct ALTER SYSTEM)
Run inside the container:
```sql
ALTER SYSTEM SET shared_buffers = '32GB';
```
Then restart Postgres.

## Verification
```sql
SHOW shared_buffers;
-- Expected: 32GB
```

## Rollback
```sql
ALTER SYSTEM SET shared_buffers = '16GB';
```
then restart.
