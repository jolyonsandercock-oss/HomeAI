---
name: check-services
description: Check all Phase 1 Docker services are running and healthy
---
Run: docker compose -f /home_ai/docker-compose.yml ps
For any service not showing 'running' or 'healthy': check its logs with docker compose logs [service] --tail=20
Report status of each Phase 1 service and any error messages found.
