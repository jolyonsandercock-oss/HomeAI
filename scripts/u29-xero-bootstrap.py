#!/usr/bin/env python3
"""
Xero OAuth 2.0 one-time bootstrap.

Interactively prompts for client_id + client_secret, runs the OAuth code
flow against Xero (popping a browser tab), captures the callback on
localhost:8976, exchanges for tokens, lists connected tenants, and writes
everything straight into Vault.

Vault layout after success:
  secret/xero/oauth                  client_id, client_secret, refresh_token
  secret/xero/tenants/<slug>         tenant_id, tenant_name
  secret/xero/trading                tenant_id   ← alias if "Trading" matched
  secret/xero/estates                tenant_id   ← alias if "Estates" matched

Pre-req:
  1. Add  http://localhost:8976/callback  to your Xero app's redirect URIs.
  2. Have VAULT_TOKEN exported (the same token you use for start.sh).
  3. You're on the host where the dashboard runs (the script's browser
     opens locally; the callback is on localhost).

Stdlib only. Tested on Python 3.10+.
"""

import base64
import getpass
import http.server
import json
import os
import secrets
import socketserver
import subprocess
import sys
import urllib.parse
import urllib.request
import webbrowser

REDIRECT_URI = "http://localhost:8976/callback"
AUTHORIZE_URL = "https://login.xero.com/identity/connect/authorize"
TOKEN_URL = "https://identity.xero.com/connect/token"
CONNECTIONS_URL = "https://api.xero.com/connections"

# Minimal, conservative scope set. Every name here is documented as a
# real Xero scope. Start narrow; widen later if the build needs more.
#   offline_access                 → REQUIRED for a refresh_token
#   accounting.transactions.read   → invoices, credit notes, bank txns, payments
#   accounting.contacts.read       → vendor + customer list
#   accounting.settings.read       → org info, accounts, tracking categories
SCOPES = " ".join([
    "offline_access",
    "accounting.transactions.read",
    "accounting.contacts.read",
    "accounting.settings.read",
])

_state = secrets.token_urlsafe(16)
_callback_result = {"code": None, "state": None, "error": None}


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_response(404); self.end_headers(); return
        params = urllib.parse.parse_qs(parsed.query)
        _callback_result["code"]  = params.get("code",  [None])[0]
        _callback_result["state"] = params.get("state", [None])[0]
        _callback_result["error"] = params.get("error", [None])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        if _callback_result["error"]:
            msg = f"<h1>Error: {_callback_result['error']}</h1><p>Check the terminal.</p>"
        else:
            msg = "<h1>Got it.</h1><p>You can close this tab and return to the terminal.</p>"
        self.wfile.write(msg.encode())

    def log_message(self, *args, **kwargs):
        pass


def _exchange_code_for_tokens(code: str, client_id: str, client_secret: str) -> dict:
    basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    body = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": REDIRECT_URI,
    }).encode()
    req = urllib.request.Request(
        TOKEN_URL, data=body,
        headers={"Authorization": f"Basic {basic}",
                 "Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def _fetch_connections(access_token: str) -> list:
    req = urllib.request.Request(
        CONNECTIONS_URL,
        headers={"Authorization": f"Bearer {access_token}",
                 "Accept": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def _vault_put(vault_token: str, path: str, **fields) -> None:
    """Use `docker exec homeai-vault vault kv put` so no Python deps needed."""
    args = ["docker", "exec", "-e", f"VAULT_TOKEN={vault_token}",
            "homeai-vault", "vault", "kv", "put", path]
    args += [f"{k}={v}" for k, v in fields.items()]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"vault kv put {path} failed: {r.stderr.strip()}")


def _slug(name: str) -> str:
    s = "".join(c.lower() if c.isalnum() else "_" for c in name)
    while "__" in s: s = s.replace("__", "_")
    return s.strip("_")


def _match_entity(name: str) -> str | None:
    """Map Xero tenant name → friendly alias. Only Trading is in scope for now."""
    n = name.lower()
    if "trading" in n: return "trading"
    return None


def main() -> None:
    print("── Xero OAuth bootstrap ─────────────────────────────────────")
    print("Prereqs:")
    print("  1. http://localhost:8976/callback is in your app's redirect URIs")
    print("  2. VAULT_TOKEN env var is set (the start.sh one)")
    print()

    vault_token = os.environ.get("VAULT_TOKEN")
    if not vault_token:
        try:
            vault_token = getpass.getpass("Vault token (kv-rw on secret/xero/*): ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.exit("\nno vault token, aborting.")
    if not vault_token:
        sys.exit("VAULT_TOKEN required.")

    try:
        client_id = input("Xero client_id: ").strip()
        client_secret = getpass.getpass("Xero client_secret (silent): ").strip()
    except (EOFError, KeyboardInterrupt):
        sys.exit("\naborted.")
    if not (client_id and client_secret):
        sys.exit("client_id and client_secret are both required.")

    auth_url = AUTHORIZE_URL + "?" + urllib.parse.urlencode({
        "response_type": "code",
        "client_id":     client_id,
        "redirect_uri":  REDIRECT_URI,
        "scope":         SCOPES,
        "state":         _state,
    })

    print("\nOpening browser to authorise the app …")
    print("If it doesn't open automatically, paste this URL into a browser:\n")
    print(auth_url)
    print("\n>> On the consent screen, select ONLY 'Atlantic Road Trading'")
    print("   (skip Atlantic Road Estates for now), then click Allow.\n")
    try:
        webbrowser.open(auth_url)
    except Exception:
        pass  # printed the URL anyway

    port = urllib.parse.urlparse(REDIRECT_URI).port or 8976
    try:
        srv = socketserver.TCPServer(("localhost", port), _CallbackHandler)
    except OSError as e:
        sys.exit(f"can't bind localhost:{port} — is another process on it? ({e})")

    print(f"Listening for callback on {REDIRECT_URI} …")
    try:
        while _callback_result["code"] is None and _callback_result["error"] is None:
            srv.handle_request()
    except KeyboardInterrupt:
        srv.server_close()
        sys.exit("\naborted.")
    srv.server_close()

    if _callback_result["error"]:
        sys.exit(f"Xero returned error: {_callback_result['error']}")
    if _callback_result["state"] != _state:
        sys.exit("state mismatch (possible CSRF). aborting.")

    print("\nGot authorisation code, exchanging for tokens …")
    tokens = _exchange_code_for_tokens(_callback_result["code"], client_id, client_secret)

    print("Fetching connections (tenant_ids) …")
    connections = _fetch_connections(tokens["access_token"])

    refresh_token = tokens["refresh_token"]

    print("\n── Writing to Vault ────────────────────────────────────────")
    _vault_put(vault_token, "secret/xero/oauth",
               client_id=client_id, client_secret=client_secret,
               refresh_token=refresh_token)
    print("  ✓ secret/xero/oauth        (3 fields)")

    aliased = {}
    for c in connections:
        name = c.get("tenantName", "<unknown>")
        tid  = c.get("tenantId",   "<missing>")
        slug = _slug(name)
        _vault_put(vault_token, f"secret/xero/tenants/{slug}",
                   tenant_id=tid, tenant_name=name)
        print(f"  ✓ secret/xero/tenants/{slug:18s} tenant_id={tid}")
        # Friendly aliases for the two entities the build expects
        alias = _match_entity(name)
        if alias and alias not in aliased:
            _vault_put(vault_token, f"secret/xero/{alias}",
                       tenant_id=tid, tenant_name=name)
            aliased[alias] = name
            print(f"  ✓ secret/xero/{alias:25s} tenant_id={tid}   (alias)")

    print()
    if "trading" not in aliased:
        print("  ! no tenant matched 'Trading' — set secret/xero/trading manually")

    print("\n── Done ────────────────────────────────────────────────────")
    print("Tenants connected:")
    for c in connections:
        print(f"  - {c.get('tenantName')}  ({c.get('tenantId')})")
    print("\nRotate-on-refresh reminder: P3 Xero Sync must overwrite "
          "secret/xero/oauth.refresh_token every time it receives a fresh one "
          "from /connect/token. The token rotates on each use.")


if __name__ == "__main__":
    main()
