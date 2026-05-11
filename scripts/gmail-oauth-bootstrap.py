#!/usr/bin/env python3
"""
gmail-oauth-bootstrap.py — one-shot helper to obtain a Gmail OAuth refresh
token and emit the Vault commands to store it. Run once per Gmail account.

WHY THIS EXISTS
---------------
Build rule (AGENTS.md): no secrets in files, no n8n credential store. The
Gmail Ingest workflow fetches client_id / client_secret / refresh_token from
Vault at runtime and exchanges the refresh token for an access token using
raw HTTP nodes. This script only seeds Vault; nothing here writes secrets to
disk.

PREREQUISITES
-------------
1. Google Cloud Console → enable Gmail API → create OAuth 2.0 Client ID of
   type "Desktop app" → download the client_secret JSON.
2. Add your Google account as a Test User on the OAuth consent screen
   (scope chosen below is sensitive; production verification not needed
   while account is internal/test).

USAGE
-----
    python3 -m venv /tmp/oauth-venv
    /tmp/oauth-venv/bin/pip install google-auth-oauthlib==1.2.1
    /tmp/oauth-venv/bin/python /home_ai/scripts/gmail-oauth-bootstrap.py \\
        --client-secret /path/to/client_secret_xxx.json \\
        --account account1

The script will open your browser for consent and print the values needed
for `vault kv put`. PREPEND A SPACE to the suggested command so it doesn't
hit your shell history (assumes HISTCONTROL=ignorespace; check yours first).

Then delete the venv and the downloaded client_secret JSON.

SCOPE
-----
Read-only Gmail (`gmail.readonly`). Pipelines that need write access (label
or reply) must request additional scopes — re-run with --scopes when added.
"""

import argparse
import json
import sys
from pathlib import Path

try:
    from google_auth_oauthlib.flow import InstalledAppFlow
except ImportError:
    sys.exit(
        "google-auth-oauthlib not installed. See PREREQUISITES in the docstring."
    )

DEFAULT_SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("USAGE")[0])
    ap.add_argument("--client-secret", required=True, type=Path,
                    help="Path to OAuth client_secret JSON downloaded from GCP")
    ap.add_argument("--account", required=True,
                    help="Account label for Vault path, e.g. account1, account2")
    ap.add_argument("--scopes", nargs="+", default=DEFAULT_SCOPES,
                    help="OAuth scopes (default: gmail.readonly)")
    args = ap.parse_args()

    if not args.client_secret.is_file():
        sys.exit(f"Not a file: {args.client_secret}")

    raw = json.loads(args.client_secret.read_text())
    installed = raw.get("installed") or raw.get("web") or {}
    client_id = installed.get("client_id")
    client_secret = installed.get("client_secret")
    if not (client_id and client_secret):
        sys.exit("client_id / client_secret not found in JSON. Wrong file?")

    flow = InstalledAppFlow.from_client_secrets_file(
        str(args.client_secret), scopes=args.scopes,
    )
    # access_type=offline + prompt=consent forces a refresh_token even on
    # repeat runs for the same Google account.
    creds = flow.run_local_server(
        port=0, access_type="offline", prompt="consent", open_browser=True,
    )

    if not creds.refresh_token:
        sys.exit("No refresh_token returned. Re-run; ensure consent prompt was shown.")

    print()
    print("=" * 70)
    print(f"OAuth flow complete for account: {args.account}")
    print(f"Scopes:        {' '.join(args.scopes)}")
    print("=" * 70)
    print()
    print("Suggested command (PREPEND A SPACE before pasting to skip shell history):")
    print()
    print(
        f" vault kv put secret/gmail/{args.account} \\\n"
        f"    oauth_client_id='{client_id}' \\\n"
        f"    oauth_client_secret='{client_secret}' \\\n"
        f"    refresh_token='{creds.refresh_token}'"
    )
    print()
    print("After: delete the venv and the client_secret JSON.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
