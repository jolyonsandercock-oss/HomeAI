#!/usr/bin/env bash
# hermes-safe: read-only system health snapshot for Hermes briefs.
set -uo pipefail
echo "$(date -Is) health-snapshot" >> /home_ai/logs/hermes-safe.log

echo "== Containers (not Up) =="
docker ps -a --format '{{.Names}}\t{{.Status}}' | awk -F'\t' '$2 !~ /^Up /' | grep . || echo "all running"

echo; echo "== Unhealthy =="
docker ps --filter health=unhealthy --format '{{.Names}}' | grep . || echo "none"

echo; echo "== Disk =="
df -h / /mnt/shared_storage | awk 'NR>1{print $6, $5, "used,", $4, "free"}'

echo; echo "== GPU =="
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo "nvidia-smi unavailable"

echo; echo "== Open system alerts =="
docker exec homeai-postgres psql -U hermes_ro -d homeai -P pager=off -tc \
  "SELECT starts_at::timestamp(0), alertname, severity, left(summary,90) FROM system_alerts WHERE status='firing' AND NOT acknowledged ORDER BY starts_at DESC LIMIT 10;" \
  2>/dev/null || echo "alerts query failed"

echo; echo "== Dead letters (24h) =="
docker exec homeai-postgres psql -U hermes_ro -d homeai -P pager=off -tc \
  "SELECT count(*) FROM dead_letter WHERE created_at > now() - interval '24 hours';" 2>/dev/null
