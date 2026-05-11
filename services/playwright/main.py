"""homeai-playwright — browser-scraping service for U27 P5/P6.

Owns two scrape endpoints, one per vendor portal:
  POST /scrape/touchoffice-z?date=YYYY-MM-DD     → daily Z-report JSON
  POST /scrape/caterbook-arrivals?date=YYYY-MM-DD → daily arrivals/summary JSON

Credentials live in Vault under secret/touchoffice and secret/caterbook
and are read at scrape time so they never sit in container env vars.

n8n hits these endpoints via the existing HTTP Request node pattern.
"""
from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from datetime import date, timedelta
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Query

# ─── Config from env ────────────────────────────────────────────
VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://vault:8200")
VAULT_TOKEN = os.environ["VAULT_TOKEN"]

log = logging.getLogger("homeai-playwright")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)


# ─── Lifespan: shared HTTP client ──────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.http = httpx.AsyncClient(timeout=10.0)
    try:
        yield
    finally:
        await app.state.http.aclose()


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


@app.post("/scrape/touchoffice-z")
async def scrape_touchoffice_z(
    report_date: str | None = Query(None, alias="date"),
) -> dict[str, Any]:
    """Stub — chunk 3 of U27 fills in the actual scrape.

    When implemented: read secret/touchoffice → launch Chromium → login at
    touchoffice.net → navigate to Z-report for `report_date` → extract table
    → return {report_date, session, net_sales, vat, gross_sales, covers,
    transactions, raw_html_path}.
    """
    target = _resolve_date(report_date)
    creds = await vault_read("secret/touchoffice")
    log.info("touchoffice scrape requested for %s (user=%s)", target, creds["username"])
    raise HTTPException(501, "touchoffice-z scrape not implemented yet — U27 chunk 3")


@app.post("/scrape/caterbook-arrivals")
async def scrape_caterbook_arrivals(
    report_date: str | None = Query(None, alias="date"),
) -> dict[str, Any]:
    """Stub — chunk 4 of U27 fills in the actual scrape.

    When implemented: read secret/caterbook (account_id + username + password)
    → launch Chromium → login at app.caterbook.net → navigate to arrivals/
    daily summary for `report_date` → extract → return {report_date,
    occupancy_pct, rooms_sold, rooms_available, room_revenue, ...,
    raw_html_path}.
    """
    target = _resolve_date(report_date)
    creds = await vault_read("secret/caterbook")
    log.info(
        "caterbook scrape requested for %s (account=%s, user=%s)",
        target, creds["account_id"], creds["username"],
    )
    raise HTTPException(501, "caterbook-arrivals scrape not implemented yet — U27 chunk 4")
