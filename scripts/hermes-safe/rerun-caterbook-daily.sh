#!/usr/bin/env bash
# hermes-safe: re-run the Caterbook daily ingest (same as the 07:00 cron).
# Idempotent: the pipeline skips already-ingested snapshots.
set -euo pipefail
echo "$(date -Is) rerun-caterbook-daily" >> /home_ai/logs/hermes-safe.log
exec bash /home_ai/scripts/u28-caterbook-daily.sh
