#!/bin/bash
# DWD probe — confirms domain-wide delegation propagated for the malthouse SA.
#
# Reads the SA JSON from Vault, mints a JWT impersonating the given target,
# exchanges for a Gmail access token, and lists 1 message. Prints PASS/FAIL.
#
# Usage:
#   bash /home_ai/.claude/scripts/dwd-probe.sh [target_email]
#
# Default target: info@malthousetintagel.com
# Reads VAULT_TOKEN from env.
set -euo pipefail

TARGET="${1:-info@malthousetintagel.com}"

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "✗ VAULT_TOKEN not set. Run: export VAULT_TOKEN='<your-token>'  first."
  exit 1
fi

echo "── DWD probe — impersonating $TARGET ──"

# Pull SA JSON from Vault
SA_JSON=$(docker exec -e VAULT_TOKEN homeai-vault \
  vault kv get -field=json_key secret/google/sa-malthouse 2>&1)

if echo "$SA_JSON" | grep -q "errors"; then
  echo "✗ Could not read secret/google/sa-malthouse: $SA_JSON"
  exit 1
fi

# Run the probe in a one-shot Python container (so we don't need pip on host)
# Mounts SA JSON via env var (never written to disk on host)
docker run --rm \
  --network home_ai_ai-egress \
  -e SA_JSON="$SA_JSON" \
  -e TARGET_EMAIL="$TARGET" \
  python:3.11-slim \
  sh -c 'pip install --quiet google-auth google-auth-httplib2 google-api-python-client && python3 - << "PYEOF"
import json, os, sys

try:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
except ImportError as e:
    print(f"✗ pip install failed: {e}", file=sys.stderr)
    sys.exit(2)

SA_JSON   = os.environ["SA_JSON"]
TARGET    = os.environ["TARGET_EMAIL"]
SCOPES    = ["https://www.googleapis.com/auth/gmail.modify"]

try:
    info  = json.loads(SA_JSON)
    creds = service_account.Credentials.from_service_account_info(
        info, scopes=SCOPES, subject=TARGET
    )
    gmail = build("gmail", "v1", credentials=creds, cache_discovery=False)
    res   = gmail.users().messages().list(userId="me", maxResults=1).execute()
    msgs  = res.get("messages", [])
    total = res.get("resultSizeEstimate", 0)
    print(f"✓ DWD works for {TARGET}")
    print(f"  total recent messages (est): {total}")
    if msgs:
        # Fetch just the headers of one message to confirm read scope
        mid = msgs[0]["id"]
        m = gmail.users().messages().get(userId="me", id=mid, format="metadata", metadataHeaders=["From","Subject"]).execute()
        hdrs = {h["name"]: h["value"] for h in m["payload"].get("headers", [])}
        from_v = hdrs.get("From", "(none)")
        subj_v = hdrs.get("Subject", "(none)")[:80]
        print("  sample message id=" + mid)
        print("    From:    " + from_v)
        print("    Subject: " + subj_v)
    else:
        print("  (inbox empty)")
    sys.exit(0)
except Exception as e:
    print(f"✗ DWD probe FAILED: {type(e).__name__}: {e}", file=sys.stderr)
    if "unauthorized_client" in str(e).lower():
        print("    → DWD scopes mismatch in admin.google.com — re-check Stage B step 6", file=sys.stderr)
    elif "invalid_grant" in str(e).lower():
        print("    → DWD not yet propagated (or wrong subject) — Workspace can take 1-2 min", file=sys.stderr)
    sys.exit(1)
PYEOF'
