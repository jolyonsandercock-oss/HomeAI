"""google-fetch — uniform Gmail/Calendar/Drive/Sheets/Docs access for n8n.

Reads identity config from static_context.gmail.accounts. Handles BOTH:
  - consumer OAuth accounts (refresh_token in Vault)
  - workspace service-account impersonation (DWD)

Endpoints:
  GET /healthz                   — liveness
  GET /accounts                  — list of active identities
  GET /messages?account=<name>   — recent Gmail messages for that identity
  GET /sendas?account=<name>     — list sendAs aliases (workspace only)

n8n calls these on every 15-min poll cycle. Token refresh is internal:
in-memory cache with TTL based on Google's expiry.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any, Optional

import asyncpg
import httpx
from fastapi import FastAPI, HTTPException, Query
from google.auth.transport.requests import Request as GAuthRequest
from google.oauth2 import service_account
from googleapiclient.discovery import build

logger = logging.getLogger("google-fetch")
logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s %(message)s")

# ─── Config from env ────────────────────────────────────────────
PG_DSN       = os.environ["PG_DSN"]
VAULT_ADDR   = os.environ.get("VAULT_ADDR", "http://vault:8200")
VAULT_TOKEN  = os.environ["VAULT_TOKEN"]

DEFAULT_SCOPES = [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/documents",
]

# ─── Token cache ────────────────────────────────────────────────
# {account_name: (access_token, expires_at_epoch)}
_TOKEN_CACHE: dict[str, tuple[str, float]] = {}

# ─── R5 mailbox → realm map (SPEC §2.5) ─────────────────────────
# Source of truth for which realm an ingested email/document belongs to.
# Keyed by `account` (the column in gmail_credentials, also stamped on
# every emails/events row). Any new mailbox must be added here before
# google-fetch will poll it — KeyError below is deliberate.
_MAILBOX_REALM: dict[str, str] = {
    "info":    "work",
    "admin":   "work",
    "stay":    "work",
    "jo":      "personal",
    "pounana": "personal",
    "bot":     "owner",
}

# ─── DB helpers ─────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await asyncpg.create_pool(PG_DSN, min_size=1, max_size=4)
    app.state.http = httpx.AsyncClient(timeout=30.0)
    try:
        yield
    finally:
        await app.state.http.aclose()
        await app.state.pool.close()


app = FastAPI(lifespan=lifespan)


async def fetch_accounts() -> list[dict[str, Any]]:
    async with app.state.pool.acquire() as conn:
        await conn.execute("SET LOCAL app.current_entity = 'all'")
        row = await conn.fetchrow(
            "SELECT value FROM static_context WHERE key='gmail.accounts'"
        )
    if not row:
        raise HTTPException(500, "static_context.gmail.accounts not seeded")
    accounts = row["value"]
    if isinstance(accounts, str):
        accounts = json.loads(accounts)
    return [a for a in accounts if a.get("active")]


async def find_account(name: str) -> dict[str, Any]:
    accounts = await fetch_accounts()
    for a in accounts:
        if a["name"] == name:
            return a
    raise HTTPException(404, f"account '{name}' not in static_context.gmail.accounts (active)")


# ─── Vault read ─────────────────────────────────────────────────
async def vault_read(path: str) -> dict[str, Any]:
    """path is like 'secret/google/jo' (without /data/ prefix — we add it)."""
    url = f"{VAULT_ADDR}/v1/{path.replace('secret/', 'secret/data/', 1)}"
    r = await app.state.http.get(url, headers={"X-Vault-Token": VAULT_TOKEN})
    if r.status_code != 200:
        raise HTTPException(500, f"vault read {path}: HTTP {r.status_code}")
    return r.json()["data"]["data"]


# ─── Telemetry ──────────────────────────────────────────────────
async def log_call(account: str, scope: str, endpoint: str,
                   status: int, duration_ms: int, error: Optional[str] = None):
    try:
        async with app.state.pool.acquire() as conn:
            await conn.execute("SET LOCAL app.current_entity = 'all'")
            await conn.execute(
                """INSERT INTO google_api_calls
                     (account, scope, endpoint, status, duration_ms, caller, error_message)
                   VALUES ($1,$2,$3,$4,$5,'google-fetch',$6)""",
                account, scope, endpoint, status, duration_ms, error
            )
    except Exception as e:
        logger.warning("telemetry write failed: %s", e)


# ─── Auth: OAuth consumer ───────────────────────────────────────
async def access_token_oauth(account: dict[str, Any]) -> str:
    name = account["name"]
    cached = _TOKEN_CACHE.get(name)
    if cached and cached[1] > time.time() + 60:
        return cached[0]

    secrets = await vault_read(account["vault_path"])
    payload = {
        "client_id":     secrets["oauth_client_id"],
        "client_secret": secrets["oauth_client_secret"],
        "refresh_token": secrets["refresh_token"],
        "grant_type":    "refresh_token",
    }
    r = await app.state.http.post("https://oauth2.googleapis.com/token", data=payload)
    if r.status_code != 200:
        raise HTTPException(502, f"oauth refresh for {name}: {r.text}")
    body = r.json()
    token = body["access_token"]
    expires = time.time() + int(body.get("expires_in", 3600))
    _TOKEN_CACHE[name] = (token, expires)
    return token


# ─── Auth: SA impersonation ─────────────────────────────────────
async def access_token_sa(account: dict[str, Any]) -> str:
    name = account["name"]
    subject = account["sa_subject"]
    cached = _TOKEN_CACHE.get(name)
    if cached and cached[1] > time.time() + 60:
        return cached[0]

    sa_blob = await vault_read(account["vault_path"])
    info = json.loads(sa_blob["json_key"])
    creds = service_account.Credentials.from_service_account_info(
        info, scopes=DEFAULT_SCOPES, subject=subject
    )
    # google-auth blocking — run in thread pool
    await asyncio.to_thread(creds.refresh, GAuthRequest())
    token = creds.token
    expires = creds.expiry.timestamp() if creds.expiry else (time.time() + 3500)
    _TOKEN_CACHE[name] = (token, expires)
    return token


async def access_token(account: dict[str, Any]) -> str:
    if account["auth"] == "oauth":
        return await access_token_oauth(account)
    elif account["auth"] == "service_account":
        return await access_token_sa(account)
    raise HTTPException(500, f"unknown auth type: {account.get('auth')}")


# ─── Endpoints ──────────────────────────────────────────────────
@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/accounts")
async def list_accounts():
    accs = await fetch_accounts()
    return {"count": len(accs), "accounts": [
        {"name": a["name"], "email": a["email"], "type": a["type"], "auth": a["auth"]}
        for a in accs
    ]}


@app.get("/messages")
async def list_messages(
    account: str = Query(...),
    newer_than: str = Query("1d", description="Gmail q syntax: 1d, 2h, 30m"),
    q: str | None = Query(None, description="Raw Gmail search query (e.g. 'subject:foo to:bar'). Overrides newer_than when set."),
    max_results: int = Query(50, ge=1, le=500),
):
    """Returns Gmail messages with header metadata.

    By default returns mail newer_than:1d. Pass `q=` for an arbitrary Gmail
    search query — used by U28 Caterbook backfill (subject + recipient filter).
    """
    acc = await find_account(account)
    tok = await access_token(acc)

    t0 = time.time()
    url = "https://gmail.googleapis.com/gmail/v1/users/me/messages"
    query = q if q else f"newer_than:{newer_than}"
    r = await app.state.http.get(
        url,
        params={"q": query, "maxResults": max_results},
        headers={"Authorization": f"Bearer {tok}"},
    )
    dur = int((time.time() - t0) * 1000)
    await log_call(account, "gmail", "messages.list", r.status_code, dur,
                   None if r.status_code == 200 else r.text[:200])

    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)

    msg_ids = [m["id"] for m in r.json().get("messages", [])]
    if not msg_ids:
        return {"account": account, "email": acc["email"], "count": 0, "messages": []}

    # Fetch metadata for each message in parallel
    async def fetch_meta(mid: str) -> dict[str, Any]:
        rr = await app.state.http.get(
            f"https://gmail.googleapis.com/gmail/v1/users/me/messages/{mid}",
            params={"format": "metadata", "metadataHeaders": ["From", "Subject", "Date", "To"]},
            headers={"Authorization": f"Bearer {tok}"},
        )
        if rr.status_code != 200:
            return {"id": mid, "error": rr.text[:200]}
        body = rr.json()
        hdrs = {h["name"].lower(): h["value"] for h in body.get("payload", {}).get("headers", [])}
        # Detect attachments: walk parts looking for filenames
        has_attachment = False
        def walk(part):
            nonlocal has_attachment
            if part.get("filename"):
                has_attachment = True
            for sub in part.get("parts", []):
                walk(sub)
        walk(body.get("payload", {}))
        return {
            "id":              mid,
            "thread_id":       body.get("threadId"),
            "from":            hdrs.get("from"),
            "to":              hdrs.get("to"),
            "subject":         hdrs.get("subject", ""),
            "date":            hdrs.get("date"),
            "snippet":         body.get("snippet", "")[:300],
            "has_attachment":  has_attachment,
            "label_ids":       body.get("labelIds", []),
            "internal_date":   body.get("internalDate"),
        }

    metas = await asyncio.gather(*[fetch_meta(mid) for mid in msg_ids])
    return {
        "account": account,
        "email":   acc["email"],
        "count":   len(metas),
        "messages": metas,
    }


@app.get("/message/{account}/{message_id}")
async def get_message(account: str, message_id: str):
    """Fetch full message body — used by classifier when it needs the body."""
    acc = await find_account(account)
    tok = await access_token(acc)
    t0 = time.time()
    r = await app.state.http.get(
        f"https://gmail.googleapis.com/gmail/v1/users/me/messages/{message_id}",
        params={"format": "full"},
        headers={"Authorization": f"Bearer {tok}"},
    )
    dur = int((time.time() - t0) * 1000)
    await log_call(account, "gmail", "messages.get", r.status_code, dur,
                   None if r.status_code == 200 else r.text[:200])
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    return r.json()


@app.get("/thread/{account}/{thread_id}")
async def get_thread(account: str, thread_id: str):
    """Fetch the full thread — used by reply-polling pipelines (u112/u113).
    Returns every message in the thread with payload included so the caller
    can scan for replies, In-Reply-To headers, and reply bodies in a single
    round-trip."""
    acc = await find_account(account)
    tok = await access_token(acc)
    t0 = time.time()
    r = await app.state.http.get(
        f"https://gmail.googleapis.com/gmail/v1/users/me/threads/{thread_id}",
        params={"format": "full"},
        headers={"Authorization": f"Bearer {tok}"},
    )
    dur = int((time.time() - t0) * 1000)
    await log_call(account, "gmail", "threads.get", r.status_code, dur,
                   None if r.status_code == 200 else r.text[:200])
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    return r.json()


@app.get("/attachments/{account}/{message_id}")
async def list_attachments(account: str, message_id: str):
    """List all attachments on a message — filename, mime_type, attachment_id, size."""
    acc = await find_account(account)
    tok = await access_token(acc)
    r = await app.state.http.get(
        f"https://gmail.googleapis.com/gmail/v1/users/me/messages/{message_id}",
        params={"format": "full"},
        headers={"Authorization": f"Bearer {tok}"},
    )
    await log_call(account, "gmail", "messages.get", r.status_code,
                   None, None if r.status_code == 200 else r.text[:200])
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    msg = r.json()
    attachments: list[dict[str, Any]] = []
    _walk_attachments(msg.get("payload") or {}, attachments)
    return {"message_id": message_id, "attachments": attachments}


@app.get("/attachment/{account}/{message_id}/{attachment_id}")
async def get_attachment(account: str, message_id: str, attachment_id: str):
    """Fetch raw attachment bytes (base64-decoded). Returns content-type +
    base64-encoded data so n8n can shuttle it around without binary-handling."""
    acc = await find_account(account)
    tok = await access_token(acc)
    t0 = time.time()
    r = await app.state.http.get(
        f"https://gmail.googleapis.com/gmail/v1/users/me/messages/{message_id}/attachments/{attachment_id}",
        headers={"Authorization": f"Bearer {tok}"},
    )
    dur = int((time.time() - t0) * 1000)
    await log_call(account, "gmail", "attachments.get", r.status_code, dur,
                   None if r.status_code == 200 else r.text[:200])
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    data = r.json().get("data", "")
    return {
        "attachment_id": attachment_id,
        "size": r.json().get("size", 0),
        "data_b64url": data,
    }


# ─── Body parsing + sanitisation ────────────────────────────────
import base64, hashlib, hmac as _hmac, re

PAYLOAD_HMAC_KEY_PATH = "secret/signing"

# Prompt-injection sanitiser, mirroring the JS version in QMKzaCFrKBS4ewWm.
_SANITISE_PATTERNS = [
    re.compile(r"ignore\s+(all\s+)?previous\s+instructions?", re.I),
    re.compile(r"forget\s+(all\s+)?instructions?", re.I),
    re.compile(r"you\s+are\s+now\s+", re.I),
    re.compile(r"new\s+instructions?:", re.I),
    re.compile(r"system\s*:", re.I),
    re.compile(r"\[INST\]", re.I), re.compile(r"\[/INST\]", re.I),
    re.compile(r"<\|im_start\|>", re.I), re.compile(r"<\|im_end\|>", re.I),
    re.compile(r"###\s*instruction", re.I),
    re.compile(r"act\s+as\s+", re.I),
    re.compile(r"pretend\s+(you\s+are|to\s+be)\s+", re.I),
    re.compile(r"override\s+(the\s+)?system", re.I),
    re.compile(r"jailbreak", re.I),
]
_HTML_TAG = re.compile(r"<[^>]*>")
_WS = re.compile(r"\s+")


def _sanitise(text: str) -> str:
    if not text:
        return ""
    clean = _HTML_TAG.sub(" ", text)
    for p in _SANITISE_PATTERNS:
        clean = p.sub("[REDACTED]", clean)
    clean = clean[:2000]
    return _WS.sub(" ", clean).strip()


def _decode_b64url(s: str) -> str:
    if not s:
        return ""
    try:
        return base64.urlsafe_b64decode(s + "=" * ((4 - len(s) % 4) % 4)).decode("utf-8", errors="replace")
    except Exception:
        return ""


def _find_text(part: dict) -> str:
    if not part:
        return ""
    if part.get("mimeType") == "text/plain" and part.get("body", {}).get("data"):
        return _decode_b64url(part["body"]["data"])
    for sub in part.get("parts") or []:
        t = _find_text(sub)
        if t:
            return t
    if part.get("mimeType") == "text/html" and part.get("body", {}).get("data"):
        return _decode_b64url(part["body"]["data"])
    return ""


def _parse_from(raw: str) -> tuple[str, str]:
    m = re.match(r'^\s*"?([^"<]*?)"?\s*<([^>]+)>\s*$', raw or "")
    if m:
        return m.group(1).strip() or None, m.group(2).strip()
    return None, raw or ""


def _walk_attachments(part: dict, out: list):
    if not part:
        return
    if part.get("filename") and part.get("body", {}).get("attachmentId"):
        out.append({
            "filename": part["filename"],
            "mime_type": part.get("mimeType", "application/octet-stream"),
            "attachment_id": part["body"]["attachmentId"],
            "size": part.get("body", {}).get("size", 0),
        })
    for sub in part.get("parts") or []:
        _walk_attachments(sub, out)


# ─── /sheets/values/{account} — proxy to Google Sheets API v4 ──
@app.get("/sheets/values/{account}/{spreadsheet_id}/{range_a1:path}")
async def sheets_values(account: str, spreadsheet_id: str, range_a1: str):
    """Fetch a range from Google Sheets. Account must have spreadsheets scope.
    range_a1 follows Sheets A1 notation, e.g. 'Sheet1!A1:Z100'."""
    acc = await find_account(account)
    tok = await access_token(acc)
    url = f"https://sheets.googleapis.com/v4/spreadsheets/{spreadsheet_id}/values/{range_a1}"
    r = await app.state.http.get(url, headers={"Authorization": f"Bearer {tok}"})
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text[:400])
    return r.json()


# ─── /send/{account} — RFC 2822 → Gmail users.messages.send ─────
from pydantic import BaseModel as _BaseModel  # local alias so this is self-contained


class SendEmailRequest(_BaseModel):
    to: str | list[str]
    subject: str
    body_text: str | None = None
    body_html: str | None = None
    cc: str | list[str] | None = None
    bcc: str | list[str] | None = None
    reply_to: str | None = None
    in_reply_to: str | None = None        # for threading replies
    references: str | None = None         # for threading replies


def _as_list(v):
    if v is None: return []
    return v if isinstance(v, list) else [v]


def _build_rfc822(from_addr: str, req: SendEmailRequest) -> bytes:
    """Build a minimal multipart/alternative RFC 2822 message."""
    from email.mime.multipart import MIMEMultipart
    from email.mime.text import MIMEText
    from email.utils import formatdate, make_msgid

    if req.body_html:
        msg = MIMEMultipart("alternative")
        msg.attach(MIMEText(req.body_text or "", "plain", "utf-8"))
        msg.attach(MIMEText(req.body_html, "html", "utf-8"))
    else:
        msg = MIMEText(req.body_text or "", "plain", "utf-8")

    msg["From"]    = from_addr
    msg["To"]      = ", ".join(_as_list(req.to))
    msg["Subject"] = req.subject
    if req.cc:        msg["Cc"]  = ", ".join(_as_list(req.cc))
    if req.bcc:       msg["Bcc"] = ", ".join(_as_list(req.bcc))
    if req.reply_to:  msg["Reply-To"] = req.reply_to
    if req.in_reply_to: msg["In-Reply-To"] = req.in_reply_to
    if req.references: msg["References"]  = req.references
    msg["Date"]      = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain="malthousetintagel.com")
    return msg.as_bytes()


@app.post("/send/{account}")
async def send_email(account: str, req: SendEmailRequest):
    """Send an email via Gmail API as `account`. Requires gmail.send (covered
    by the gmail.modify scope already in DEFAULT_SCOPES). Returns the sent
    message id + thread id."""
    import base64
    acc = await find_account(account)
    tok = await access_token(acc)

    raw = _build_rfc822(acc["email"], req)
    encoded = base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")

    t0 = time.time()
    body: dict[str, Any] = {"raw": encoded}
    if req.in_reply_to:
        # Best-effort threading — if the original message id matches a thread
        # we'd want to set threadId here. Gmail finds the thread by header
        # most of the time, so leaving threadId off is usually fine.
        pass

    r = await app.state.http.post(
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
        json=body,
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
    )
    dur = int((time.time() - t0) * 1000)
    await log_call(account, "gmail", "messages.send", r.status_code, dur,
                   None if r.status_code == 200 else r.text[:300])

    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)

    body = r.json()
    return {
        "account":     account,
        "from":        acc["email"],
        "to":          _as_list(req.to),
        "message_id":  body.get("id"),
        "thread_id":   body.get("threadId"),
        "label_ids":   body.get("labelIds", []),
        "size":        len(raw),
    }


@app.post("/draft/{account}")
async def create_draft(account: str, req: SendEmailRequest):
    """Create a Gmail DRAFT (not sent) as `account` — lands in the account's
    Drafts folder for review/edit/send. Covered by gmail.modify."""
    import base64
    acc = await find_account(account)
    tok = await access_token(acc)
    raw = _build_rfc822(acc["email"], req)
    encoded = base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")
    t0 = time.time()
    r = await app.state.http.post(
        "https://gmail.googleapis.com/gmail/v1/users/me/drafts",
        json={"message": {"raw": encoded}},
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
    )
    dur = int((time.time() - t0) * 1000)
    await log_call(account, "gmail", "drafts.create", r.status_code, dur,
                   None if r.status_code == 200 else r.text[:300])
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    body = r.json()
    return {
        "account":    account,
        "draft_id":   body.get("id"),
        "message_id": body.get("message", {}).get("id"),
        "to":         _as_list(req.to),
        "subject":    req.subject,
    }


# ─── /forward — preserve attachments via raw RFC822 ────────────
@app.post("/forward/{account}/{message_id}")
async def forward_email(account: str, message_id: str,
                         to: str = Query(..., description="forward recipient"),
                         prepend_subject: str = Query("Fwd: ", description="subject prefix")):
    """U128: forward a Gmail message verbatim (with attachments) to `to`.
    Fetches raw RFC822, rewrites headers (To, From, Subject prefix),
    posts back via messages.send. Used by u128-forward-orphans.sh to
    auto-forward invoice emails to malthousepub@dext.cc when Xero doesn't
    have a matching bill within 7 days."""
    import base64, email
    from email.utils import formatdate, make_msgid

    acc = await find_account(account)
    tok = await access_token(acc)

    t0 = time.time()
    r = await app.state.http.get(
        f"https://gmail.googleapis.com/gmail/v1/users/me/messages/{message_id}",
        params={"format": "raw"},
        headers={"Authorization": f"Bearer {tok}"},
    )
    await log_call(account, "gmail", "messages.get(raw)", r.status_code,
                   int((time.time() - t0) * 1000),
                   None if r.status_code == 200 else r.text[:200])
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)

    raw_b64 = r.json().get("raw", "")
    raw_bytes = base64.urlsafe_b64decode(raw_b64 + "=" * (-len(raw_b64) % 4))
    msg = email.message_from_bytes(raw_bytes)

    # Rewrite headers — drop original routing, set new From/To/Subject.
    for h in ("To", "Cc", "Bcc", "Delivered-To", "Return-Path",
              "From", "Reply-To", "Sender", "Subject",
              "Message-ID", "DKIM-Signature", "X-Google-DKIM-Signature",
              "ARC-Authentication-Results", "ARC-Message-Signature", "ARC-Seal",
              "Authentication-Results", "Received", "Received-SPF"):
        del msg[h]
    orig_subject = email.message_from_bytes(raw_bytes).get("Subject", "(no subject)")
    msg["From"]       = acc["email"]
    msg["To"]         = to
    msg["Subject"]    = f"{prepend_subject}{orig_subject}"
    msg["Date"]       = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain="malthousetintagel.com")

    encoded = base64.urlsafe_b64encode(msg.as_bytes()).rstrip(b"=").decode("ascii")

    t0 = time.time()
    r2 = await app.state.http.post(
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
        json={"raw": encoded},
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
    )
    await log_call(account, "gmail", "messages.send(forward)", r2.status_code,
                   int((time.time() - t0) * 1000),
                   None if r2.status_code == 200 else r2.text[:300])
    if r2.status_code != 200:
        raise HTTPException(r2.status_code, r2.text)

    body = r2.json()
    return {
        "account":           account,
        "original_id":       message_id,
        "forwarded_to":      to,
        "subject":           msg["Subject"],
        "forwarded_message_id": body.get("id"),
        "thread_id":         body.get("threadId"),
        "size":              len(msg.as_bytes()),
    }


# ─── /poll-and-emit ─────────────────────────────────────────────
@app.post("/poll-and-emit")
async def poll_and_emit(newer_than: str = Query("1d"), max_per_account: int = Query(50, ge=1, le=200)):
    """One-call multi-account ingestion. Iterates all active accounts, fetches new
    messages, builds HMAC-signed event payloads, atomically claims idempotency keys
    and INSERTs email.received events. Returns per-account stats."""
    accounts = await fetch_accounts()
    sig_blob = await vault_read(PAYLOAD_HMAC_KEY_PATH)
    hmac_key = sig_blob["payload_hmac_key"].encode()

    results = []
    async with app.state.pool.acquire() as conn:
        for acc in accounts:
            name = acc["name"]
            email = acc["email"]
            try:
                tok = await access_token(acc)

                # List recent message IDs
                r = await app.state.http.get(
                    "https://gmail.googleapis.com/gmail/v1/users/me/messages",
                    params={"q": f"newer_than:{newer_than}", "maxResults": max_per_account},
                    headers={"Authorization": f"Bearer {tok}"},
                )
                if r.status_code != 200:
                    results.append({"account": name, "error": r.text[:200]})
                    continue
                msg_ids = [m["id"] for m in r.json().get("messages", [])]

                inserted = 0; skipped = 0; errors = 0
                for mid in msg_ids:
                    try:
                        # Fetch full body
                        rr = await app.state.http.get(
                            f"https://gmail.googleapis.com/gmail/v1/users/me/messages/{mid}",
                            params={"format": "full"},
                            headers={"Authorization": f"Bearer {tok}"},
                        )
                        if rr.status_code != 200:
                            errors += 1
                            continue
                        msg = rr.json()
                        payload = msg.get("payload") or {}
                        headers = payload.get("headers") or []
                        h = {x["name"].lower(): x["value"] for x in headers}

                        from_raw = h.get("from", "")
                        from_name, from_address = _parse_from(from_raw)
                        body_text = _find_text(payload)
                        body_text_safe = _sanitise(body_text)
                        attachments = []
                        _walk_attachments(payload, attachments)
                        has_attachment = bool(attachments)

                        internal = msg.get("internalDate")
                        if internal:
                            from datetime import datetime, timezone
                            received_at = datetime.fromtimestamp(int(internal) / 1000, tz=timezone.utc).isoformat()
                        else:
                            received_at = h.get("date")

                        # R5: realm derived from mailbox-of-receipt. KeyError
                        # by design if a new account ships without a mapping
                        # — better a loud poll failure than silent owner-tag.
                        realm = _MAILBOX_REALM[name]

                        event_payload = {
                            "gmail_message_id": mid,
                            "account": name,
                            "realm": realm,
                            "from_address": from_address,
                            "from_name": from_name,
                            "subject": h.get("subject", ""),
                            "body_text": body_text,
                            "body_text_safe": body_text_safe,
                            "received_at": received_at,
                            "has_attachment": has_attachment,
                        }
                        canonical = json.dumps(event_payload, sort_keys=True, separators=(",", ":"))
                        signature = _hmac.new(hmac_key, canonical.encode(), hashlib.sha256).hexdigest()
                        idem_key = f"email_{mid}"

                        # Atomic claim + insert in a single transaction.
                        # email.received claim is gated, but document.received claims are
                        # INDEPENDENT — so re-polling existing emails will backfill any
                        # missing attachment events. Per U43 fix — without this, the
                        # Invoice Pipeline P2 dead-letters every invoice.detected because
                        # the sibling document.received never arrives.
                        async with conn.transaction():
                            await conn.execute("SET LOCAL app.current_entity = 'all'")
                            claimed = await conn.fetchval(
                                "SELECT claim_idempotency_key($1, 'gmail-poller-py')",
                                idem_key,
                            )
                            if claimed:
                                await conn.execute(
                                    """INSERT INTO events
                                         (event_type, source, entity_id, payload, payload_signature,
                                          idempotency_key, pipeline_version, realm)
                                       VALUES ('email.received', 'gmail', NULL, $1::jsonb, $2,
                                               $3, 'gmail_poller_py:1.3', $4)""",
                                    json.dumps(event_payload), signature, idem_key, realm,
                                )
                                inserted += 1
                            else:
                                skipped += 1

                            # Per-attachment document.received emission (U43 fix).
                            # Runs REGARDLESS of whether email.received was newly claimed,
                            # so this also backfills attachment events for emails that
                            # were polled before U43.
                            # U47d: Gmail rotates `attachment_id` on every fetch (verified
                            # 71 distinct ids for the same file in one hour), so it cannot
                            # be used as an idempotency key. Use (mid, part_index, size)
                            # instead — stable across re-polls.
                            for idx, att in enumerate(attachments):
                                doc_payload = {
                                    "gmail_message_id": mid,
                                    "account": name,
                                    "realm": realm,
                                    "filename": att["filename"],
                                    "mime_type": att["mime_type"],
                                    "attachment_id": att["attachment_id"],
                                    "size": att["size"],
                                }
                                doc_canon = json.dumps(doc_payload, sort_keys=True, separators=(",", ":"))
                                doc_sig   = _hmac.new(hmac_key, doc_canon.encode(), hashlib.sha256).hexdigest()
                                doc_idem  = f"doc_{mid}_p{idx}_{att['size']}"
                                doc_claimed = await conn.fetchval(
                                    "SELECT claim_idempotency_key($1, 'gmail-poller-py')",
                                    doc_idem,
                                )
                                if doc_claimed:
                                    await conn.execute(
                                        """INSERT INTO events
                                             (event_type, source, entity_id, payload, payload_signature,
                                              idempotency_key, pipeline_version, realm)
                                           VALUES ('document.received', 'gmail', NULL, $1::jsonb, $2,
                                                   $3, 'gmail_poller_py:1.3', $4)""",
                                        json.dumps(doc_payload), doc_sig, doc_idem, realm,
                                    )
                    except Exception as e:
                        logger.exception("message %s/%s failed: %s", name, mid, e)
                        errors += 1

                results.append({
                    "account": name, "email": email,
                    "fetched": len(msg_ids),
                    "inserted": inserted, "skipped_duplicate": skipped, "errors": errors,
                })
            except Exception as e:
                logger.exception("account %s failed: %s", name, e)
                results.append({"account": name, "error": str(e)[:200]})

    return {"results": results, "total_inserted": sum(r.get("inserted", 0) for r in results)}
