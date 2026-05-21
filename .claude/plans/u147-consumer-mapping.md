# U147 — consumer mapping (service → role)

V177 applied 2026-05-21. Pen-test passed (trading/personal/owner isolation confirmed on emails + vendor_invoice_inbox).

The roles are dormant until consumers are migrated to use them. Below is the proposed mapping. **Requires Jo's sign-off before applying** — wrong role on a service breaks it.

## Mapping

| service | current role | proposed role | rationale |
|---|---|---|---|
| build-dashboard | homeai_pipeline | trading_role | dashboard reads work data only |
| homeai-frontend | homeai_pipeline | trading_role | /app/* shows work realm |
| bot-responder | homeai_pipeline | owner_role | needs cross-realm reads for queries |
| critical-listener | homeai_pipeline | owner_role | system-wide audit writes |
| llm-router | homeai_pipeline | owner_role | logs ai_usage across realms |
| homeai-n8n (pipelines) | homeai_pipeline | owner_role | writes to events table for all event types/realms |
| google-fetch | homeai_pipeline | owner_role | writes emails for all realms |
| paperless | homeai_readonly | trading_role | docs ingest is work-realm |
| homeai-litellm | homeai_pipeline | owner_role | logs ai_usage across realms |
| homeai-presidio | (no DB) | n/a | stateless |
| homeai-data-proxy | homeai_pipeline | owner_role | proxies everything |
| metabase | homeai_readonly | owner_role | exploratory dashboards see all |

## How to apply (per service)

1. Update `docker-compose.yml` env var `PG_USER` (or equivalent) to the new role.
2. `docker compose up -d <service>` to restart with new role.
3. Verify service health endpoint + a representative API call.
4. Watch `audit_log` for any `connection refused` / `permission denied` errors.

## Rollback

For any service that breaks: change `PG_USER` back to `homeai_pipeline` or `homeai_readonly`, restart. Roles will be re-grantable if needed.

## Post-migration cleanup (after 24h soak)

- Confirm zero connections under legacy `homeai_readonly` / `homeai_pipeline` via `pg_stat_activity`.
- New migration V179 drops the legacy roles.

## Status

- ✅ V177 applied to live (3 roles + grants)
- ✅ Pen-test green on emails + vendor_invoice_inbox
- ⏸ Service migration **awaiting Jo's sign-off**
