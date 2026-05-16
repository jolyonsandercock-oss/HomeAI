"""wa-bridge — WhatsApp Web sidecar.

Drives WhatsApp Web with Playwright. Two persistent profiles (personal,
pub) each saved to a host-mounted dir so the QR-pair survives container
restarts. FastAPI surfaces the bridge as HTTP for cron jobs and the
bot-responder.

ENDPOINTS
  GET  /healthz
  GET  /accounts                       — which profiles have been QR-paired
  POST /accounts/{a}/pair              — open WA Web in headed mode for QR
  POST /accounts/{a}/scrape            — pull recent threads → wa_messages
  POST /accounts/{a}/send              — direct send (bypasses approval gate)
  GET  /accounts/{a}/threads           — list active threads from DB
  GET  /accounts/{a}/thread/{jid}      — last N messages in a thread
  POST /outbound/dispatch              — ship every status='approved' row in wa_outbound_queue

OWNER-APPROVAL FLOW
  1. Drafter (cron/script/bot) INSERTs into wa_outbound_queue (status='pending_approval')
  2. u118-approval-loop reads pending rows, posts each to Telegram with YES/NO buttons
  3. Jo approves → status='approved'
  4. /outbound/dispatch (called every 5 min by cron) ships the row, marks status='sent'

WA TOS NOTE
  This is WhatsApp Web automation, not the Business Cloud API. WhatsApp may
  ban the account. Throttle conservatively (max 1 send / 6s, max 30/hr) and
  do not bulk-blast. Used sparingly for personal-touch comms only.
"""
import os, asyncio, hashlib, json, logging, time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

import asyncpg
from fastapi import FastAPI, HTTPException, Body

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(name)s: %(message)s')
log = logging.getLogger('wa-bridge')

PG_DSN     = os.environ['PG_DSN']
PROFILE_DIR = Path(os.environ.get('WA_PROFILE_DIR', '/wa-profiles'))
SEND_GAP_S = float(os.environ.get('WA_SEND_GAP_S', '6'))      # min seconds between sends
HOURLY_CAP = int(os.environ.get('WA_HOURLY_CAP', '30'))       # max sends/hr per account

WA_URL = "https://web.whatsapp.com"

# Realm mapping
ACCOUNT_REALM = {'personal': 'family', 'pub': 'work'}


@asynccontextmanager
async def lifespan(app: FastAPI):
    from playwright.async_api import async_playwright
    app.state.pool = await asyncpg.create_pool(PG_DSN, min_size=1, max_size=4)
    app.state.pw = await async_playwright().start()
    app.state.contexts = {}   # account → BrowserContext
    app.state.last_send = {}  # account → epoch of last send
    yield
    for ctx in app.state.contexts.values():
        try: await ctx.close()
        except Exception: pass
    await app.state.pw.stop()
    await app.state.pool.close()


app = FastAPI(lifespan=lifespan, title='wa-bridge')


async def _profile(app, account: str, headless: bool = True):
    """Return a (re-)used BrowserContext for the given account profile."""
    if account not in ACCOUNT_REALM:
        raise HTTPException(400, f"unknown account '{account}'")
    if account in app.state.contexts and not app.state.contexts[account].pages:
        await app.state.contexts[account].close()
        del app.state.contexts[account]
    if account not in app.state.contexts:
        prof = PROFILE_DIR / account
        prof.mkdir(parents=True, exist_ok=True)
        ctx = await app.state.pw.chromium.launch_persistent_context(
            str(prof),
            headless=headless,
            viewport={'width': 1280, 'height': 900},
            user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
                       '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        )
        app.state.contexts[account] = ctx
    return app.state.contexts[account]


async def _page(ctx, url=WA_URL):
    pages = ctx.pages
    if pages:
        page = pages[0]
    else:
        page = await ctx.new_page()
    if page.url != url:
        await page.goto(url, wait_until='domcontentloaded', timeout=30000)
    return page


@app.get('/healthz')
async def healthz():
    return {'status': 'ok'}


@app.get('/accounts')
async def list_accounts():
    out = {}
    for acc in ACCOUNT_REALM:
        prof = PROFILE_DIR / acc
        paired = prof.exists() and any(prof.iterdir())
        out[acc] = {
            'realm': ACCOUNT_REALM[acc],
            'profile_exists': paired,
            'profile_path': str(prof),
            'context_open': acc in app.state.contexts,
        }
    return out


@app.post('/accounts/{account}/pair')
async def pair(account: str):
    """Open WhatsApp Web in HEADED mode for one-time QR pairing.

    Note: this requires X11/Wayland or VNC into the container. In practice
    Jo runs this once with `docker exec -it homeai-wa-bridge ...` against a
    standalone Playwright launch — see PAIRING.md.
    """
    return {'instructions': 'See /home_ai/services/wa-bridge/PAIRING.md — '
            'QR pairing must be done interactively. This endpoint will not '
            'open a visible browser inside a container without a display.'}


@app.post('/accounts/{account}/scrape')
async def scrape(account: str):
    """Open WA Web, walk recent threads, insert any new messages."""
    ctx = await _profile(app, account)
    page = await _page(ctx)
    # Wait for chat list to load — if not signed in, side panel never appears
    try:
        await page.wait_for_selector('[aria-label="Chat list"]', timeout=15000)
    except Exception:
        return {'error': 'chat list not found — likely not paired. '
                'See /home_ai/services/wa-bridge/PAIRING.md'}

    inserted = 0
    # Iterate top N chats (most recent)
    chats = await page.locator('[aria-label="Chat list"] [role="listitem"]').all()
    for chat in chats[:20]:
        try:
            await chat.click()
            await page.wait_for_timeout(1200)
            # Title of opened thread
            title = await page.locator('header [title]').first.text_content()
            # Pull every visible message bubble
            bubbles = await page.locator('div.message-in, div.message-out').all()
            for b in bubbles[-30:]:
                try:
                    text = (await b.locator('span.selectable-text').first.text_content()) or ''
                    if not text.strip():
                        continue
                    cls = (await b.get_attribute('class')) or ''
                    direction = 'inbound' if 'message-in' in cls else 'outbound'
                    # Best-effort timestamp from data-pre-plain-text
                    pp = await b.get_attribute('data-pre-plain-text') or ''
                    # Hash for dedup
                    h = hashlib.sha256(
                        f'{account}|{title}|{text}|{pp}|{direction}'.encode()
                    ).hexdigest()
                    async with app.state.pool.acquire() as conn:
                        r = await conn.execute("""
                            INSERT INTO wa_messages
                              (account, thread_jid, direction, body, body_hash,
                               sent_at, realm, raw)
                            VALUES ($1, $2, $3, $4, $5, NOW(), $6, $7::jsonb)
                            ON CONFLICT (account, body_hash) DO NOTHING
                        """, account, title or 'unknown', direction, text, h,
                             ACCOUNT_REALM[account],
                             json.dumps({'pp': pp, 'class': cls}))
                        if 'INSERT 0 1' in r:
                            inserted += 1
                except Exception as e:
                    log.warning('bubble parse fail: %s', e)
        except Exception as e:
            log.warning('chat click fail: %s', e)
    return {'account': account, 'threads_scanned': len(chats[:20]), 'inserted': inserted}


@app.post('/accounts/{account}/send')
async def send(account: str, payload: dict = Body(...)):
    """Direct send — used by /outbound/dispatch + manual override.

    Body: {"target": "+447xxx" or "Name", "body": "text"}
    Returns: {"sent_at": "...", "wa_msg_id": "..."}
    """
    target = (payload.get('target') or '').strip()
    body   = (payload.get('body') or '').strip()
    if not target or not body:
        raise HTTPException(400, 'target + body required')

    # Throttle
    now = time.time()
    last = app.state.last_send.get(account, 0)
    if now - last < SEND_GAP_S:
        await asyncio.sleep(SEND_GAP_S - (now - last))
    # Per-hour cap
    async with app.state.pool.acquire() as conn:
        hr_count = await conn.fetchval("""
            SELECT COUNT(*) FROM wa_messages
             WHERE account = $1 AND direction = 'outbound'
               AND sent_at >= NOW() - INTERVAL '1 hour'
        """, account)
    if hr_count >= HOURLY_CAP:
        raise HTTPException(429, f'hourly send cap ({HOURLY_CAP}) reached for {account}')

    ctx = await _profile(app, account)
    page = await _page(ctx)
    try:
        await page.wait_for_selector('[aria-label="Chat list"]', timeout=15000)
    except Exception:
        raise HTTPException(503, 'not paired — see PAIRING.md')

    # WA Web's "wa.me" deep link inside the open session opens chat directly
    if target.startswith('+') or target.replace(' ', '').isdigit():
        phone = ''.join(c for c in target if c.isdigit())
        await page.goto(f'{WA_URL}/send?phone={phone}', timeout=20000)
        await page.wait_for_selector('[contenteditable="true"][data-tab="10"]', timeout=15000)
    else:
        # Search chat by name
        await page.locator('[aria-label="Search input"]').first.click()
        await page.keyboard.type(target)
        await page.wait_for_timeout(1200)
        chat = page.locator(f'[aria-label*="{target}"]').first
        await chat.click()
        await page.wait_for_timeout(500)

    composer = page.locator('[contenteditable="true"][data-tab="10"]').first
    await composer.click()
    await composer.type(body, delay=20)
    await page.wait_for_timeout(200)
    await composer.press('Enter')
    await page.wait_for_timeout(800)

    app.state.last_send[account] = time.time()
    sent_at = datetime.now(timezone.utc)
    h = hashlib.sha256(f'{account}|{target}|{body}|{sent_at.isoformat()}'.encode()).hexdigest()
    async with app.state.pool.acquire() as conn:
        wid = await conn.fetchval("""
            INSERT INTO wa_messages
              (account, thread_jid, direction, body, body_hash, sent_at, realm)
            VALUES ($1, $2, 'outbound', $3, $4, $5, $6)
            ON CONFLICT (account, body_hash) DO NOTHING
            RETURNING id
        """, account, target, body, h, sent_at, ACCOUNT_REALM[account])
    return {'sent_at': sent_at.isoformat(), 'wa_msg_id': wid}


@app.get('/accounts/{account}/threads')
async def threads(account: str, limit: int = 50):
    async with app.state.pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT thread_jid,
                   MAX(sent_at) AS last_at,
                   COUNT(*) FILTER (WHERE direction='inbound') AS in_count,
                   COUNT(*) FILTER (WHERE direction='outbound') AS out_count
              FROM wa_messages
             WHERE account = $1
             GROUP BY thread_jid
             ORDER BY MAX(sent_at) DESC
             LIMIT $2
        """, account, limit)
    return [dict(r) for r in rows]


@app.get('/accounts/{account}/thread/{jid:path}')
async def thread(account: str, jid: str, limit: int = 50):
    async with app.state.pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT direction, body, sent_at
              FROM wa_messages
             WHERE account = $1 AND thread_jid = $2
             ORDER BY sent_at DESC
             LIMIT $3
        """, account, jid, limit)
    return [dict(r) for r in rows]


@app.post('/outbound/dispatch')
async def dispatch():
    """Ship every status='approved' row in wa_outbound_queue."""
    async with app.state.pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT id, account, target_jid, target_label, body
              FROM wa_outbound_queue
             WHERE status = 'approved'
             ORDER BY approved_at NULLS FIRST, created_at
             LIMIT 20
        """)
    sent = 0
    for r in rows:
        try:
            resp = await send(r['account'], {'target': r['target_jid'], 'body': r['body']})
            async with app.state.pool.acquire() as conn:
                await conn.execute("""
                    UPDATE wa_outbound_queue
                       SET status='sent', sent_at=NOW(), sent_msg_id=$1
                     WHERE id=$2
                """, resp.get('wa_msg_id'), r['id'])
            sent += 1
        except HTTPException as e:
            async with app.state.pool.acquire() as conn:
                await conn.execute("""
                    UPDATE wa_outbound_queue
                       SET status='failed'
                     WHERE id=$1
                """, r['id'])
            log.error('dispatch %s failed: %s', r['id'], e.detail)
        except Exception as e:
            log.error('dispatch %s error: %s', r['id'], e)
    return {'approved_seen': len(rows), 'sent': sent}
