"""TouchOffice (touchoffice.net) scraper for the daily Department Sales report.

The report is rendered as absolutely-positioned divs in `pt` units inside
`.rptPagePadding` — TouchOffice emulates a PDF in the browser. There is no
semantic HTML (no <table>, no labels), so we extract by sorting divs by
(top, left) position, grouping into rows, and reading column values by the
known column-left offsets seen on the live report.

Known column offsets (pt):
    11.34 → Number
    68.03 → Department
   249.45 → Quantity     (right-aligned)
   345.83 → (£) Value    (right-aligned)
   442.20 → (%) Ratio    (right-aligned)
"""
from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any

from playwright.async_api import Page, async_playwright

log = logging.getLogger("homeai-playwright.touchoffice")

BASE_URL = "https://www.touchoffice.net"
LOGIN_URL = f"{BASE_URL}/"
REPORT_VIEW_URL = f"{BASE_URL}/reports_engine/report_view"

# ── helpers ────────────────────────────────────────────────────
_PT_RE = re.compile(r"(\w+)\s*:\s*([-\d.]+)\s*pt")
_NUM_RE = re.compile(r"-?[\d,]+(?:\.\d+)?")


def _parse_pt(style: str, key: str) -> float | None:
    """Pull out e.g. 'top: 119.06pt' from an inline style string."""
    for m in _PT_RE.finditer(style or ""):
        if m.group(1) == key:
            try:
                return float(m.group(2))
            except ValueError:
                return None
    return None


def _parse_num(s: str) -> float | None:
    """Parse '1,466.34' → 1466.34; '100.00' → 100.0; '-' or empty → None."""
    if not s:
        return None
    m = _NUM_RE.search(s)
    if not m:
        return None
    try:
        return float(m.group(0).replace(",", ""))
    except ValueError:
        return None


async def _collect_positioned_divs(page: Page) -> list[tuple[float, float, str]]:
    """Return [(top_pt, left_pt, text), …] for every child div with text inside .rptPagePadding."""
    divs = await page.locator(".rptPagePadding > div").all()
    items: list[tuple[float, float, str]] = []
    for d in divs:
        style = (await d.get_attribute("style")) or ""
        text = ((await d.text_content()) or "").strip()
        if not text:
            continue
        top = _parse_pt(style, "top")
        left = _parse_pt(style, "left")
        if top is None or left is None:
            continue
        items.append((top, left, text))
    items.sort(key=lambda x: (round(x[0], 1), x[1]))
    return items


def _group_into_rows(
    items: list[tuple[float, float, str]],
    row_tolerance_pt: float = 2.0,
) -> list[list[tuple[float, str]]]:
    """Group items with similar `top` into rows; within a row, left-sorted."""
    rows: list[list[tuple[float, str]]] = []
    current: list[tuple[float, str]] = []
    last_top: float | None = None
    for top, left, text in items:
        if last_top is None or abs(top - last_top) > row_tolerance_pt:
            if current:
                rows.append(current)
            current = []
            last_top = top
        current.append((left, text))
    if current:
        rows.append(current)
    return rows


def _parse_department_sales(rows: list[list[tuple[float, str]]]) -> dict[str, Any]:
    """Walk the grouped rows and pull out site + date range + per-dept lines + total."""
    out: dict[str, Any] = {
        "site": None,
        "date_range": None,
        "departments": [],
        "total": {},
    }
    for row in rows:
        texts = [t for _, t in row]
        first = texts[0] if texts else ""

        # Date range row: contains "To" between two date-times.
        if any("To" in t and ":" in t for t in texts) and first.startswith("Date Range"):
            # Date range label + value rendered as two divs on same top — combine.
            joined = " ".join(t for _, t in row)
            m = re.search(r"(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})\s+To\s+(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})", joined)
            if m:
                out["date_range"] = {"from": m.group(1), "to": m.group(2)}
            continue

        # Site row
        if first.startswith("Site:"):
            out["site"] = first.removeprefix("Site:").strip()
            continue

        # Total row
        if first == "Total" and len(texts) >= 4:
            out["total"] = {
                "quantity": _parse_num(texts[1]),
                "value":    _parse_num(texts[2]),
                "ratio_pct": _parse_num(texts[3]),
            }
            continue

        # Per-department row: starts with an integer (the dept number).
        if first.isdigit() and len(texts) >= 5:
            out["departments"].append({
                "number":    int(first),
                "name":      texts[1],
                "quantity":  _parse_num(texts[2]),
                "value":     _parse_num(texts[3]),
                "ratio_pct": _parse_num(texts[4]),
            })

    return out


# ── orchestrator ───────────────────────────────────────────────
async def scrape(
    username: str,
    password: str,
    report_date: str,
    *,
    snapshot_dir: Path = Path("/host-tmp"),
    headless: bool = True,
) -> dict[str, Any]:
    """Login → navigate to Department Sales for `report_date` → extract.

    Returns a dict with `site`, `date_range`, `departments`, `total`, and
    diagnostic fields. Saves an HTML snapshot to /host-tmp on failure so we
    can iterate without re-running the whole flow.
    """
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=headless,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
        )
        ctx = await browser.new_context()
        page = await ctx.new_page()
        try:
            # 1. Login
            log.info("touchoffice: login")
            await page.goto(LOGIN_URL, wait_until="domcontentloaded")
            await page.fill("#username", username)
            await page.fill("#password", password)
            await page.click('button[name="submit-login"]')
            await page.wait_for_load_state("networkidle", timeout=30000)

            # 2. Navigate to the rendered report view.
            #    TODO(U27 chunk 3.1): the date is set via the report-selection
            #    page (URL TBD). For now, navigate directly to the report view —
            #    if it doesn't render the wrapper, dump the HTML so we can
            #    iterate on the actual navigation path.
            log.info("touchoffice: navigating to %s", REPORT_VIEW_URL)
            await page.goto(REPORT_VIEW_URL, wait_until="domcontentloaded")

            # 3. Wait for the report wrapper or fail with a diagnostic dump.
            try:
                await page.wait_for_selector(".rptPageWrapper", timeout=15000)
            except Exception as e:  # noqa: BLE001
                snapshot_dir.mkdir(parents=True, exist_ok=True)
                snap_html = snapshot_dir / f"touchoffice-no-report-{report_date}.html"
                snap_png = snapshot_dir / f"touchoffice-no-report-{report_date}.png"
                snap_html.write_text(await page.content())
                await page.screenshot(path=str(snap_png), full_page=True)
                log.error("report did not render — debug: %s, %s", snap_html, snap_png)
                raise RuntimeError(
                    f"report not rendered after navigation; "
                    f"debug saved to {snap_html} + {snap_png}"
                ) from e

            # 4. Extract.
            items = await _collect_positioned_divs(page)
            rows = _group_into_rows(items)
            parsed = _parse_department_sales(rows)
            parsed["report_type"] = "department_sales"
            parsed["report_date"] = report_date
            parsed["rendered_divs"] = len(items)
            log.info(
                "touchoffice: parsed %d departments, total=%s",
                len(parsed["departments"]), parsed["total"],
            )
            return parsed

        finally:
            await browser.close()
