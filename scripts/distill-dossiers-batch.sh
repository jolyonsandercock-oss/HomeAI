#!/usr/bin/env bash
# distill-dossiers-batch.sh — nightly eager/incremental dossier distillation.
# Distils up to BATCH stale high-signal counterparties via build-dashboard.
# Owner realm (cultural memory spans all). Cost-paced: one batch per run.
set -euo pipefail
BATCH="${1:-25}"
curl -fsS -X POST -H 'X-Realm: owner' \
  "http://homeai-build-dashboard:8090/api/memory/distill-batch?limit=${BATCH}" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("distilled",d.get("distilled"),"errors",len(d.get("errors",[])))'
