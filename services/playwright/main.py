"""homeai-playwright — browser-scraping service for U27 P5/P6.

Owns:
  POST /scrape/touchoffice?date=YYYY-MM-DD&site=malthouse|sandwich
       → JSON with fixed_totals / department_sales_total / plu_sales widgets
  POST /ingest/touchoffice?date=YYYY-MM-DD&site=…
       → scrape + INSERT into 3 widget tables, independent per-widget
         try/except, status logged to touchoffice_scrapes.
  POST /scrape/caterbook-arrivals?date=YYYY-MM-DD
       → stub until U27 chunk 4

Credentials live in Vault under secret/touchoffice and secret/caterbook
and are read at scrape time so they never sit in container env vars.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from datetime import date, timedelta
from typing import Any

import asyncpg
import httpx
from fastapi import FastAPI, HTTPException, Query

# ─── Config from env ────────────────────────────────────────────
VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://vault:8200")
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ.get("PG_DSN", "")  # may be empty in scrape-only deployments

log = logging.getLogger("homeai-playwright")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)


# ─── Lifespan: shared HTTP client + DB pool ────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.http = httpx.AsyncClient(timeout=10.0)
    app.state.pool = None
    if PG_DSN:
        # Retry across postgres-not-ready races at boot. Without this, a
        # cold-start where postgres comes up after playwright leaves the pool
        # permanently None and /ingest 503s until manual restart.
        delay = 2.0
        for attempt in range(1, 11):
            try:
                app.state.pool = await asyncpg.create_pool(PG_DSN, min_size=1, max_size=4)
                log.info("postgres pool ready (attempt %d)", attempt)
                break
            except Exception as e:  # noqa: BLE001
                log.warning("pool attempt %d failed: %s — retrying in %.0fs", attempt, e, delay)
                await asyncio.sleep(delay)
                delay = min(delay * 1.5, 30.0)
        if app.state.pool is None:
            log.error("postgres pool never opened after 10 attempts — /ingest will 503")
    try:
        yield
    finally:
        await app.state.http.aclose()
        if app.state.pool is not None:
            await app.state.pool.close()


app = FastAPI(title="homeai-playwright", lifespan=lifespan)


# ─── Vault read ─────────────────────────────────────────────────
async def vault_read(path: str) -> dict[str, Any]:
    """Read a Vault KV v2 secret. `path` like 'secret/touchoffice'."""
    url = f"{VAULT_ADDR}/v1/{path.replace('secret/', 'secret/data/', 1)}"
    r = await app.state.http.get(url, headers={"X-Vault-Token": VAULT_TOKEN})
    if r.status_code != 200:
        raise HTTPException(500, f"vault read {path}: HTTP {r.status_code}")
    return r.json()["data"]["data"]


# ─── Health ─────────────────────────────────────────────────────
@app.get("/healthz")
async def healthz() -> dict[str, Any]:
    # Cheap liveness — does NOT touch Vault or external sites.
    return {"status": "ok"}


@app.get("/readyz")
async def readyz() -> dict[str, Any]:
    # Readiness: can we reach Vault?
    try:
        r = await app.state.http.get(f"{VAULT_ADDR}/v1/sys/health", timeout=2.0)
        return {"status": "ok", "vault_status": r.status_code}
    except Exception as e:  # noqa: BLE001
        raise HTTPException(503, f"vault unreachable: {e}")


# ─── Scrape endpoints (stubs — chunks 3+4) ─────────────────────
def _resolve_date(d: str | None) -> str:
    if d:
        try:
            return date.fromisoformat(d).isoformat()
        except ValueError:
            raise HTTPException(400, f"invalid date '{d}' — expected YYYY-MM-DD")
    return (date.today() - timedelta(days=1)).isoformat()


@app.post("/scrape/touchoffice")
async def scrape_touchoffice(
    report_date: str | None = Query(None, alias="date"),
    site: str = Query("malthouse", description="malthouse | sandwich"),
) -> dict[str, Any]:
    """Scrape TouchOffice home-page widgets (FIXED TOTALS, DEPARTMENT SALES
    TOTAL, PLU SALES) for the given site + date.
    """
    from scrapers import touchoffice
    target = _resolve_date(report_date)
    creds = await vault_read("secret/touchoffice")
    log.info("touchoffice scrape: date=%s site=%s user=%s", target, site, creds["username"])
    try:
        return await touchoffice.scrape(
            username=creds["username"],
            password=creds["password"],
            report_date=target,
            site=site,
        )
    except RuntimeError as e:
        raise HTTPException(502, str(e))


# Back-compat shim so an existing wiring to the old name keeps working.
@app.post("/scrape/touchoffice-z")
async def scrape_touchoffice_z_compat(
    report_date: str | None = Query(None, alias="date"),
    site: str = Query("malthouse"),
) -> dict[str, Any]:
    return await scrape_touchoffice(report_date=report_date, site=site)


# ─── /ingest/touchoffice — scrape + write 3 widget tables ───────
async def _ingest_widget(
    conn: asyncpg.Connection,
    *,
    table: str,
    site: str,
    report_date: str,
    rows: list[dict[str, Any]],
    extract_row: Any,
) -> int:
    """Run SET LOCAL + INSERT ... ON CONFLICT DO NOTHING for one widget.

    `extract_row(row_dict)` returns the tuple of column values matching the
    INSERT statement built per-table below. Returns rows inserted.
    """
    inserted = 0
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for row in rows:
            try:
                values = extract_row(row)
                # Each table has site, report_date, idempotency_key + widget cols.
                if table == "touchoffice_fixed_totals":
                    # U46 fix: DO UPDATE not DO NOTHING — earlier scrapes captured
                    # in-progress totals; the last scrape of the day is canonical.
                    n = await conn.fetchval(
                        """
                        INSERT INTO touchoffice_fixed_totals
                          (idempotency_key, site, report_date, totaliser_id, label, quantity, value, raw_cells)
                        VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
                        ON CONFLICT (site, report_date, totaliser_id) DO UPDATE
                          SET label = EXCLUDED.label,
                              quantity = EXCLUDED.quantity,
                              value = EXCLUDED.value,
                              raw_cells = EXCLUDED.raw_cells
                        RETURNING 1
                        """, *values,
                    )
                elif table == "touchoffice_department_sales":
                    n = await conn.fetchval(
                        """
                        INSERT INTO touchoffice_department_sales
                          (idempotency_key, site, report_date, department, quantity, value, raw_cells)
                        VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb)
                        ON CONFLICT (site, report_date, department) DO UPDATE
                          SET quantity = EXCLUDED.quantity,
                              value = EXCLUDED.value,
                              raw_cells = EXCLUDED.raw_cells
                        RETURNING 1
                        """, *values,
                    )
                elif table == "touchoffice_plu_sales":
                    n = await conn.fetchval(
                        """
                        INSERT INTO touchoffice_plu_sales
                          (idempotency_key, site, report_date, plu_number, descriptor, quantity, value, raw_cells)
                        VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
                        ON CONFLICT (site, report_date, plu_number) DO UPDATE
                          SET descriptor = EXCLUDED.descriptor,
                              quantity = EXCLUDED.quantity,
                              value = EXCLUDED.value,
                              raw_cells = EXCLUDED.raw_cells
                        RETURNING 1
                        """, *values,
                    )
                else:
                    raise ValueError(f"unknown table {table}")
                if n:
                    inserted += 1
            except Exception as e:  # noqa: BLE001
                log.warning("ingest %s row error: %s — row=%s", table, e, row)
    return inserted


def _num(s: str | None) -> float | None:
    if not s:
        return None
    s = s.replace("£", "").replace(",", "").strip()
    try:
        return float(s)
    except ValueError:
        return None


@app.post("/ingest/touchoffice")
async def ingest_touchoffice(
    report_date: str | None = Query(None, alias="date"),
    site: str = Query("malthouse", description="malthouse | sandwich"),
) -> dict[str, Any]:
    """Scrape a (site, date) and INSERT each of the 3 widgets into its table.

    Per-widget INSERTs are wrapped in independent try/except. The
    touchoffice_scrapes table gets one row per widget so each pipeline can
    be monitored independently.
    """
    if app.state.pool is None:
        raise HTTPException(503, "postgres pool not configured (PG_DSN missing)")

    target = _resolve_date(report_date)
    target_date = date.fromisoformat(target)  # asyncpg wants native date for DATE cols
    creds = await vault_read("secret/touchoffice")
    t0 = time.monotonic()

    from scrapers import touchoffice
    try:
        scrape = await touchoffice.scrape(
            username=creds["username"],
            password=creds["password"],
            report_date=target,
            site=site,
        )
    except Exception as e:  # noqa: BLE001
        runtime_ms = int((time.monotonic() - t0) * 1000)
        async with app.state.pool.acquire() as conn:
            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity = '1'")
                for w in ("fixed_totals", "department_sales", "plu_sales"):
                    await conn.execute(
                        """INSERT INTO touchoffice_scrapes
                            (site, report_date, widget, success, error_message, scrape_runtime_ms)
                           VALUES ($1,$2,$3,false,$4,$5)""",
                        site, target_date, w, str(e)[:1000], runtime_ms,
                    )
        raise HTTPException(502, f"scrape failed: {e}")

    runtime_ms = int((time.monotonic() - t0) * 1000)

    def _ikey(*parts: Any) -> str:
        s = "|".join(str(p) for p in parts)
        return f"to_{hashlib.sha256(s.encode()).hexdigest()[:24]}"

    results: dict[str, Any] = {
        "report_date": target,
        "site": site,
        "scrape_runtime_ms": runtime_ms,
        "snapshot_html": scrape.get("_snapshot_html"),
        "snapshot_png":  scrape.get("_snapshot_png"),
        "widgets": {},
    }

    # ── Each widget INSERTed in its own transaction so they don't block each other.
    async with app.state.pool.acquire() as conn:
        # FIXED TOTALS — totaliser_id / label / quantity / value
        widget_status: dict[str, Any] = {}
        try:
            ft_rows = scrape.get("fixed_totals", {}).get("rows", [])
            def ft_extract(r: dict[str, Any]) -> tuple:
                tid = r.get("totaliser_id")
                label = r.get("label") or (r.get("cells", [None])[0] or "")
                cells = r.get("cells", [])
                qty = _num(cells[1]) if len(cells) > 1 else None
                val = _num(cells[2]) if len(cells) > 2 else None
                return (
                    _ikey("ft", site, target, tid),
                    site, target_date, tid, label, qty, val,
                    json.dumps(cells),
                )
            inserted = await _ingest_widget(
                conn, table="touchoffice_fixed_totals", site=site, report_date=target,
                rows=ft_rows, extract_row=ft_extract,
            )
            widget_status = {"success": True, "scraped": len(ft_rows), "inserted": inserted}
        except Exception as e:  # noqa: BLE001
            widget_status = {"success": False, "error": str(e)[:300]}
        results["widgets"]["fixed_totals"] = widget_status
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '1'")
            await conn.execute(
                """INSERT INTO touchoffice_scrapes
                    (site, report_date, widget, success, rows_written, error_message,
                     scrape_runtime_ms, snapshot_html_path, snapshot_png_path)
                   VALUES ($1,$2,'fixed_totals',$3,$4,$5,$6,$7,$8)""",
                site, target_date, widget_status["success"],
                widget_status.get("inserted"), widget_status.get("error"),
                runtime_ms, scrape.get("_snapshot_html"), scrape.get("_snapshot_png"),
            )

        # DEPARTMENT SALES — department / quantity / value
        widget_status = {}
        try:
            ds_rows = scrape.get("department_sales_total", {}).get("rows", [])
            def ds_extract(r: dict[str, Any]) -> tuple:
                cells = r.get("cells", [])
                dept = cells[0] if cells else None
                qty = _num(cells[1]) if len(cells) > 1 else None
                val = _num(cells[2]) if len(cells) > 2 else None
                return (
                    _ikey("ds", site, target, dept),
                    site, target_date, dept, qty, val,
                    json.dumps(cells),
                )
            inserted = await _ingest_widget(
                conn, table="touchoffice_department_sales", site=site, report_date=target,
                rows=ds_rows, extract_row=ds_extract,
            )
            widget_status = {"success": True, "scraped": len(ds_rows), "inserted": inserted}
        except Exception as e:  # noqa: BLE001
            widget_status = {"success": False, "error": str(e)[:300]}
        results["widgets"]["department_sales"] = widget_status
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '1'")
            await conn.execute(
                """INSERT INTO touchoffice_scrapes
                    (site, report_date, widget, success, rows_written, error_message,
                     scrape_runtime_ms, snapshot_html_path, snapshot_png_path)
                   VALUES ($1,$2,'department_sales',$3,$4,$5,$6,$7,$8)""",
                site, target_date, widget_status["success"],
                widget_status.get("inserted"), widget_status.get("error"),
                runtime_ms, scrape.get("_snapshot_html"), scrape.get("_snapshot_png"),
            )

        # PLU SALES — plu_number / descriptor / quantity / value
        widget_status = {}
        try:
            plu_rows = scrape.get("plu_sales", {}).get("rows", [])
            def plu_extract(r: dict[str, Any]) -> tuple:
                cells = r.get("cells", [])
                plu = cells[0] if cells else None
                desc = cells[1] if len(cells) > 1 else None
                qty = _num(cells[2]) if len(cells) > 2 else None
                val = _num(cells[3]) if len(cells) > 3 else None
                return (
                    _ikey("plu", site, target, plu),
                    site, target_date, plu, desc, qty, val,
                    json.dumps(cells),
                )
            inserted = await _ingest_widget(
                conn, table="touchoffice_plu_sales", site=site, report_date=target,
                rows=plu_rows, extract_row=plu_extract,
            )
            widget_status = {"success": True, "scraped": len(plu_rows), "inserted": inserted}
        except Exception as e:  # noqa: BLE001
            widget_status = {"success": False, "error": str(e)[:300]}
        results["widgets"]["plu_sales"] = widget_status
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '1'")
            await conn.execute(
                """INSERT INTO touchoffice_scrapes
                    (site, report_date, widget, success, rows_written, error_message,
                     scrape_runtime_ms, snapshot_html_path, snapshot_png_path)
                   VALUES ($1,$2,'plu_sales',$3,$4,$5,$6,$7,$8)""",
                site, target_date, widget_status["success"],
                widget_status.get("inserted"), widget_status.get("error"),
                runtime_ms, scrape.get("_snapshot_html"), scrape.get("_snapshot_png"),
            )

    return results


@app.post("/scrape/caterbook-arrivals")
async def scrape_caterbook_arrivals(
    report_date: str | None = Query(None, alias="date"),
) -> dict[str, Any]:
    """PARKED — Caterbook is ingested from email (U28), not browser-scraped.

    See POST /ingest/caterbook for the email-driven path. This endpoint stays
    as a 501 so any old wiring fails loudly rather than silently.
    """
    raise HTTPException(501, "caterbook browser scrape parked — use /ingest/caterbook (email-driven)")


# ─── /ingest/caterbook — pull an email's PDF, parse, INSERT observations ──
GOOGLE_FETCH_URL = os.environ.get("GOOGLE_FETCH_URL", "http://google-fetch:8011")
PDFPLUMBER_URL   = os.environ.get("PDFPLUMBER_URL",   "http://homeai-pdfplumber:8003")


async def _gf_message_meta(account: str, message_id: str) -> dict[str, Any]:
    r = await app.state.http.get(
        f"{GOOGLE_FETCH_URL}/message/{account}/{message_id}", timeout=15.0,
    )
    if r.status_code != 200:
        raise HTTPException(r.status_code, f"google-fetch message: {r.text[:300]}")
    return r.json()


async def _gf_attachment(account: str, message_id: str, attachment_id: str) -> bytes:
    import base64
    r = await app.state.http.get(
        f"{GOOGLE_FETCH_URL}/attachment/{account}/{message_id}/{attachment_id}",
        timeout=60.0,
    )
    if r.status_code != 200:
        raise HTTPException(r.status_code, f"google-fetch attachment: {r.text[:300]}")
    b = r.json()["data_b64url"]
    pad = "=" * (-len(b) % 4)
    return base64.urlsafe_b64decode(b + pad)


def _find_pdf_attachment(payload: dict[str, Any]) -> tuple[str, str] | None:
    """Walk the Gmail payload tree to find the first application/pdf part.
    Returns (filename, attachment_id) or None."""
    def walk(part: dict[str, Any]) -> tuple[str, str] | None:
        mt = part.get("mimeType", "")
        body = part.get("body") or {}
        if mt == "application/pdf" and body.get("attachmentId"):
            return part.get("filename") or "attachment.pdf", body["attachmentId"]
        for sub in part.get("parts", []) or []:
            r = walk(sub)
            if r is not None:
                return r
        return None
    return walk(payload)


@app.post("/ingest/caterbook")
async def ingest_caterbook(
    account: str = Query("info"),
    message_id: str = Query(...),
) -> dict[str, Any]:
    """Fetch a Caterbook 'Arrivals and Departures' email by message_id,
    parse the PDF, INSERT observations + email report + daily snapshot.

    Idempotent: ON CONFLICT DO NOTHING + UNIQUE constraints across all writes.
    """
    if app.state.pool is None:
        raise HTTPException(503, "postgres pool not configured")

    from scrapers.caterbook import parse_pdf_text

    msg = await _gf_message_meta(account, message_id)
    pdf_info = _find_pdf_attachment(msg.get("payload", {}))
    if pdf_info is None:
        raise HTTPException(422, "no PDF attachment in this message")
    filename, attachment_id = pdf_info

    pdf_bytes = await _gf_attachment(account, message_id, attachment_id)

    # Persist the raw PDF to /host-tmp for replay/debug.
    pdf_dir = "/host-tmp/caterbook"
    os.makedirs(pdf_dir, exist_ok=True)
    raw_pdf_path = f"{pdf_dir}/{message_id}.pdf"
    with open(raw_pdf_path, "wb") as f:
        f.write(pdf_bytes)

    # PDF → text via pdfplumber.
    files = {"file": (filename, pdf_bytes, "application/pdf")}
    r = await app.state.http.post(f"{PDFPLUMBER_URL}/extract-pdf", files=files, timeout=60.0)
    if r.status_code != 200:
        raise HTTPException(r.status_code, f"pdfplumber: {r.text[:300]}")
    pdf_text = r.json()["text"]
    raw_text_path = f"{pdf_dir}/{message_id}.txt"
    with open(raw_text_path, "w") as f:
        f.write(pdf_text)

    parsed = parse_pdf_text(pdf_text)
    report_date_obj: date | None = parsed["report_date"]
    observations = parsed["observations"]
    if report_date_obj is None:
        raise HTTPException(422, "could not extract report_date from PDF")

    # Received_at — parse from message header (RFC 2822) or fall back to internalDate.
    received_at = None
    hdrs = {h["name"].lower(): h["value"]
            for h in msg.get("payload", {}).get("headers", [])}
    date_hdr = hdrs.get("date")
    if date_hdr:
        try:
            from email.utils import parsedate_to_datetime
            received_at = parsedate_to_datetime(date_hdr)
        except Exception:  # noqa: BLE001
            pass
    if received_at is None:
        try:
            received_at = datetime.fromtimestamp(int(msg.get("internalDate", "0")) / 1000)
        except Exception:  # noqa: BLE001
            received_at = datetime.utcnow()

    arrivals  = [o for o in observations if o.section == "arrivals"]
    stayovers = [o for o in observations if o.section == "stayovers"]
    departs   = [o for o in observations if o.section == "departures"]

    import hashlib

    def _ikey(*parts: Any) -> str:
        return hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()[:32]

    def _obs_dict(o):
        return {
            "ref": o.ref, "room": o.room, "guest": o.guest_name,
            "type": o.room_type, "rate": o.rate_code, "guests": o.guests_code,
            "contact": o.contact, "status": o.status,
            "balance": o.balance,
            "dep": o.departure_date_seen.isoformat() if o.departure_date_seen else None,
        }

    inserted_obs = 0
    skipped_obs  = 0
    async with app.state.pool.acquire() as conn:
        # 1. Email report row.
        email_report_id = None
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '1'")
            email_report_id = await conn.fetchval(
                """
                INSERT INTO caterbook_email_reports
                  (idempotency_key, source_email_id, account, report_date, received_at,
                   arrivals_count, stayovers_count, departures_count,
                   total_balance_seen, raw_pdf_path, raw_text_path)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
                ON CONFLICT (source_email_id) DO UPDATE SET ingested_at = now()
                RETURNING id
                """,
                f"cb_email_{message_id}",
                message_id, account, report_date_obj, received_at,
                len(arrivals), len(stayovers), len(departs),
                sum((o.balance or 0) for o in observations),
                raw_pdf_path, raw_text_path,
            )

        # 2. Observation rows.
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '1'")
            for o in observations:
                ikey = f"cb_obs_{_ikey(report_date_obj.isoformat(), o.ref, o.room, o.section)}"
                n = await conn.fetchval(
                    """
                    INSERT INTO caterbook_observations
                      (idempotency_key, email_report_id, report_date, section,
                       guest_name, room, ref, room_type, rate_code, guests_code,
                       contact, status, balance, departure_date_seen, raw_cells)
                    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15::jsonb)
                    ON CONFLICT (report_date, ref, room, section) DO NOTHING
                    RETURNING 1
                    """,
                    ikey, email_report_id, report_date_obj, o.section,
                    o.guest_name, o.room, o.ref, o.room_type, o.rate_code, o.guests_code,
                    o.contact, o.status, o.balance, o.departure_date_seen,
                    json.dumps({"raw_line": o.raw_line}),
                )
                if n:
                    inserted_obs += 1
                else:
                    skipped_obs += 1

        # 3. Daily snapshot row.
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '1'")
            await conn.execute(
                """
                INSERT INTO caterbook_daily_snapshots
                  (idempotency_key, email_report_id, report_date,
                   arrivals, stayovers, departures,
                   arrivals_count, stayovers_count, departures_count,
                   in_house_count, revenue_in_house)
                VALUES ($1,$2,$3,$4::jsonb,$5::jsonb,$6::jsonb,$7,$8,$9,$10,$11)
                ON CONFLICT (report_date) DO UPDATE SET
                  email_report_id  = EXCLUDED.email_report_id,
                  arrivals         = EXCLUDED.arrivals,
                  stayovers        = EXCLUDED.stayovers,
                  departures       = EXCLUDED.departures,
                  arrivals_count   = EXCLUDED.arrivals_count,
                  stayovers_count  = EXCLUDED.stayovers_count,
                  departures_count = EXCLUDED.departures_count,
                  in_house_count   = EXCLUDED.in_house_count,
                  revenue_in_house = EXCLUDED.revenue_in_house
                """,
                f"cb_snap_{report_date_obj.isoformat()}",
                email_report_id, report_date_obj,
                json.dumps([_obs_dict(o) for o in arrivals]),
                json.dumps([_obs_dict(o) for o in stayovers]),
                json.dumps([_obs_dict(o) for o in departs]),
                len(arrivals), len(stayovers), len(departs),
                len(arrivals) + len(stayovers),
                sum((o.balance or 0) for o in arrivals + stayovers),
            )

    return {
        "report_date": report_date_obj.isoformat(),
        "source_email_id": message_id,
        "email_report_id": email_report_id,
        "observations_inserted": inserted_obs,
        "observations_skipped": skipped_obs,
        "arrivals": len(arrivals),
        "stayovers": len(stayovers),
        "departures": len(departs),
        "raw_pdf_path": raw_pdf_path,
    }


# ─── U229 Dojo + U230 Trail (stubs — auth pairing required on-site) ─

@app.post("/scrape/dojo")
async def scrape_dojo(
    date_from: str | None = Query(None),
    date_to:   str | None = Query(None),
) -> dict[str, Any]:
    """Scrape Dojo merchant dashboard transactions. Stub until on-site pairing.
    See scrapers/dojo.py for the pairing procedure.
    """
    from datetime import date as _date
    from scrapers import dojo as dojo_scraper

    creds = await vault_read("secret/dojo")
    df = _date.fromisoformat(date_from) if date_from else None
    dt = _date.fromisoformat(date_to)   if date_to   else None
    try:
        rows = await dojo_scraper.scrape(
            username=creds["username"], password=creds["password"],
            date_from=df, date_to=dt,
        )
    except RuntimeError as e:
        raise HTTPException(503, f"dojo scrape failed: {e}")
    return {"rows": rows, "count": len(rows)}


@app.post("/ingest/dojo")
async def ingest_dojo(
    date_from: str | None = Query(None),
    date_to:   str | None = Query(None),
) -> dict[str, Any]:
    """Scrape Dojo + upsert into dojo_transactions on (transaction_id)."""
    payload = await scrape_dojo(date_from=date_from, date_to=date_to)
    rows = payload["rows"]
    if not rows:
        return {"inserted": 0, "skipped": 0, "rows": 0, "note": "stub or empty range"}

    conn = await asyncpg.connect(PG_DSN)
    try:
        inserted = skipped = 0
        async with conn.transaction():
            for r in rows:
                rc = await conn.execute(
                    """
                    INSERT INTO dojo_transactions
                        (transaction_id, mid, site, address, location,
                         transaction_date, transaction_time, transaction_type,
                         amount, currency, card_type, status, source, realm)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
                            'playwright', 'work')
                    ON CONFLICT (transaction_id) DO NOTHING
                    """,
                    r["transaction_id"], r["mid"], r["site"], r["address"],
                    r.get("location"), r["transaction_date"], r["transaction_time"],
                    r["transaction_type"], r["amount"], r.get("currency", "GBP"),
                    r.get("card_type"), r.get("status"),
                )
                if rc.endswith("0"):
                    skipped += 1
                else:
                    inserted += 1
        return {"inserted": inserted, "skipped": skipped, "rows": len(rows)}
    finally:
        await conn.close()


@app.post("/scrape/trail")
async def scrape_trail(
    date_from: str | None = Query(None),
    date_to:   str | None = Query(None),
) -> dict[str, Any]:
    """Scrape Trail food-hygiene reports via OIDC SSO. Stub until on-site pairing."""
    from datetime import date as _date
    from scrapers import trail as trail_scraper

    creds = await vault_read("secret/trail")
    df = _date.fromisoformat(date_from) if date_from else None
    dt = _date.fromisoformat(date_to)   if date_to   else None
    try:
        rows = await trail_scraper.scrape(
            username=creds["username"], password=creds["password"],
            date_from=df, date_to=dt,
        )
    except RuntimeError as e:
        raise HTTPException(503, f"trail scrape failed: {e}")
    return {"rows": rows, "count": len(rows)}


@app.post("/ingest/trail")
async def ingest_trail(
    date_from: str | None = Query(None),
    date_to:   str | None = Query(None),
) -> dict[str, Any]:
    """Scrape Trail + upsert into trail_reports on (trail_report_id, report_date)."""
    payload = await scrape_trail(date_from=date_from, date_to=date_to)
    rows = payload["rows"]
    if not rows:
        return {"inserted": 0, "skipped": 0, "rows": 0, "note": "stub or empty range"}

    conn = await asyncpg.connect(PG_DSN)
    try:
        inserted = skipped = 0
        async with conn.transaction():
            for r in rows:
                rc = await conn.execute(
                    """
                    INSERT INTO trail_reports
                        (trail_report_id, location, report_name, report_date,
                         cadence, score_pct, tasks_total, tasks_completed,
                         tasks_overdue, realm)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'work')
                    ON CONFLICT (trail_report_id, report_date) DO UPDATE SET
                        score_pct = EXCLUDED.score_pct,
                        tasks_completed = EXCLUDED.tasks_completed,
                        tasks_overdue = EXCLUDED.tasks_overdue
                    """,
                    r["trail_report_id"], r["location"], r["report_name"],
                    r["report_date"], r["cadence"], r.get("score_pct"),
                    r.get("tasks_total"), r.get("tasks_completed"),
                    r.get("tasks_overdue"),
                )
                if rc.endswith("0"):
                    skipped += 1
                else:
                    inserted += 1
        return {"inserted": inserted, "skipped": skipped, "rows": len(rows)}
    finally:
        await conn.close()
