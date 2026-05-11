#!/usr/bin/env python3
"""
google-oauth-bootstrap.py — Sprint U9 Stage C
Walks 3 consumer Gmail accounts through OAuth and stores refresh tokens in Vault.

Reads:  secret/google/oauth-client (must exist)
Writes: secret/google/{jo,pounana,bot}

Pre-flight:
  - VAULT_TOKEN exported in shell
  - OAuth client has http://localhost:8089/oauth-callback registered
  - You can open a browser on this machine (the P620 GUI, OR remotely
    if you forward port 8089 + can paste the URL)

Run:
  python3 /home_ai/.claude/scripts/google-oauth-bootstrap.py
"""

import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser

REDIRECT_URI = "http://localhost:8089/oauth-callback"
PORT         = 8089

SCOPES = " ".join([
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/documents",
    "openid",
    "email",
])

ACCOUNTS = [
    ("jo",      "jolyon.sandercock@gmail.com"),
    ("pounana", "pounana@gmail.com"),
    ("bot",     "jolyboxbot@gmail.com"),
]


# ── Vault helpers ───────────────────────────────────────────────
def vault_read_field(path: str, field: str) -> str:
    cmd = ["docker", "exec", "-e", "VAULT_TOKEN", "homeai-vault",
           "vault", "kv", "get", "-field", field, path]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"vault read {path}/{field}: {r.stderr.strip()}")
    return r.stdout.strip()


def vault_write_json(path: str, data: dict) -> None:
    """Write k=v pairs to Vault using stdin JSON to avoid arg-quoting issues."""
    payload = json.dumps(data)
    cmd = ["docker", "exec", "-i", "-e", "VAULT_TOKEN",
           "homeai-vault", "vault", "kv", "put", path, "-"]
    r = subprocess.run(cmd, input=payload, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"vault write {path}: {r.stderr.strip()}")


# ── Local OAuth callback server ─────────────────────────────────
captured = {"code": None, "error": None}
done_event = threading.Event()


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return  # silence default access log

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/oauth-callback":
            self.send_response(404); self.end_headers(); return
        params = urllib.parse.parse_qs(parsed.query)
        if "error" in params:
            captured["error"] = params["error"][0]
            body = b"<h1>Auth failed - return to terminal</h1>"
        elif "code" in params:
            captured["code"] = params["code"][0]
            body = b"<h1>Captured. Return to terminal.</h1>"
        else:
            body = b"<h1>No code or error in callback</h1>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        done_event.set()


# ── OAuth flow per account ──────────────────────────────────────
def run_oauth_for_account(label: str, email: str, client_id: str, client_secret: str) -> dict:
    captured["code"] = None
    captured["error"] = None
    done_event.clear()

    auth_params = {
        "response_type":  "code",
        "client_id":      client_id,
        "redirect_uri":   REDIRECT_URI,
        "scope":          SCOPES,
        "access_type":    "offline",
        "prompt":         "consent",
        "login_hint":     email,
        "include_granted_scopes": "true",
    }
    auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(auth_params)

    # Listen for callback (fresh server per account — clean shutdown each time)
    socketserver.TCPServer.allow_reuse_address = True
    server = socketserver.TCPServer(("localhost", PORT), CallbackHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    try:
        print(f"\nOpening browser for {email}.")
        print("If browser doesn't open, paste this URL manually:\n")
        print(auth_url)
        print()
        try:
            webbrowser.open(auth_url)
        except Exception:
            pass
        print("Waiting for OAuth callback (5 min timeout)...")
        if not done_event.wait(timeout=300):
            raise TimeoutError("No OAuth callback received within 5 min")
    finally:
        server.shutdown()
        server.server_close()

    if captured["error"]:
        raise RuntimeError(f"Google returned error: {captured['error']}")
    if not captured["code"]:
        raise RuntimeError("No code captured")

    # Exchange code for tokens
    payload = urllib.parse.urlencode({
        "code":          captured["code"],
        "client_id":     client_id,
        "client_secret": client_secret,
        "redirect_uri":  REDIRECT_URI,
        "grant_type":    "authorization_code",
    }).encode()
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())

    if "refresh_token" not in body:
        raise RuntimeError(
            "No refresh_token in response — Google may not have issued one because "
            "this client+account was already authorized. Revoke at "
            "https://myaccount.google.com/permissions and retry."
        )
    return body


def verify_token(access_token: str, expected_email: str) -> str:
    """Returns the email Gmail says the token belongs to."""
    req = urllib.request.Request(
        "https://gmail.googleapis.com/gmail/v1/users/me/profile",
        headers={"Authorization": "Bearer " + access_token},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read())
    return body.get("emailAddress", "")


# ── Main ────────────────────────────────────────────────────────
def main() -> int:
    if not os.environ.get("VAULT_TOKEN"):
        sys.stderr.write("✗ VAULT_TOKEN not set. Run:  export VAULT_TOKEN='<token>'  first.\n")
        return 1

    print("── Reading OAuth client from Vault ──")
    try:
        client_id     = vault_read_field("secret/google/oauth-client", "client_id")
        client_secret = vault_read_field("secret/google/oauth-client", "client_secret")
    except Exception as e:
        sys.stderr.write(f"✗ {e}\n")
        return 1
    print(f"  client_id (head): {client_id[:30]}...")

    print(f"\nAbout to authorise {len(ACCOUNTS)} accounts:")
    for label, email in ACCOUNTS:
        print(f"  {label:8s} — {email}")
    print("\nFor each: browser opens, you sign in to that account, click Allow.")
    print("Press Ctrl-C anytime to abort the remaining accounts.\n")

    results = []
    for label, email in ACCOUNTS:
        try:
            input(f"Press Enter to start OAuth for {label} ({email}): ")
        except (KeyboardInterrupt, EOFError):
            print("\nAborted by user.")
            break

        try:
            tokens = run_oauth_for_account(label, email, client_id, client_secret)
            actual = verify_token(tokens["access_token"], email)
            if actual.lower() != email.lower():
                print(f"  ⚠ /me returned '{actual}' — expected '{email}'. Account-picker confusion?")
                print(f"    Skipping write to Vault for {label}.")
                results.append((label, f"WRONG ACCOUNT: signed in as {actual}"))
                continue

            vault_write_json(f"secret/google/{label}", {
                "email_address":       email,
                "oauth_client_id":     client_id,
                "oauth_client_secret": client_secret,
                "refresh_token":       tokens["refresh_token"],
                "scopes":              SCOPES,
            })
            print(f"  ✓ {label}: stored at secret/google/{label} (verified email: {actual})")
            results.append((label, "ok"))
        except Exception as e:
            print(f"  ✗ {label}: {e}")
            results.append((label, str(e)))

    print("\n── Summary ──")
    for label, status in results:
        mark = "✓" if status == "ok" else "✗"
        print(f"  {mark} {label}: {status}")

    return 0 if all(s == "ok" for _, s in results) else 1


if __name__ == "__main__":
    sys.exit(main())
