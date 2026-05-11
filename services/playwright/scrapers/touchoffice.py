"""TouchOffice (touchoffice.net) scraper — home-page widget data.

After login, the TouchOffice home dashboard hosts 17 widgets. Three of them
hold the rows we want:

  - FIXED TOTALS              widget div id=fixed_totals             table id=fixedtotals
  - DEPARTMENT SALES TOTAL    widget div id=department_sales_total   (table loaded by AJAX)
  - PLU SALES                 widget div id=plu_sales                (table loaded by AJAX)

Controls:
  - `<form id="filter">` with `#dateselect-start` / `#dateselect-end` (DD/MM/YYYY)
  - `<select name="site" id="site">`  (1 = Malthouse, 2 = Sandwich Bar, 0 = Head Office aggregate)
  - `<button name="submit-filter">` to apply

On submit, each widget refreshes via AJAX. The scraper:
  1. Logs in.
  2. Sets the date inputs + site select.
  3. Clicks submit-filter.
  4. Waits for the widget tables to appear.
  5. Parses each widget's <table> with a generic thead+tbody walker.
  6. Returns three dicts (`fixed_totals`, `department_sales_total`, `plu_sales`)
     plus diagnostic snapshot paths.
"""
from __future__ import annotations

import logging
import re
from datetime import date as date_cls
from pathlib import Path
from typing import Any

from playwright.async_api import Page, async_playwright

log = logging.getLogger("homeai-playwright.touchoffice")

BASE_URL = "https://www.touchoffice.net"

SITES = {
    "malthouse": {"value": "1", "label": "Malthouse",    "kind": "pub"},
    "sandwich":  {"value": "2", "label": "Sandwich Bar", "kind": "ice_cream"},
    # 'head_office' (0) is the aggregate — not used by the pipeline, but exposed
    # in case we want a cross-site sanity check.
    "head_office": {"value": "0", "label": "Head Office", "kind": "aggregate"},
}

WIDGETS = {
    "fixed_totals":           {"div_id": "fixed_totals",           "title": "FIXED TOTALS"},
    "department_sales_total": {"div_id": "department_sales_total", "title": "DEPARTMENT SALES TOTAL"},
    "plu_sales":              {"div_id": "plu_sales",              "title": "PLU SALES"},
}


def _uk_date(iso_date: str) -> str:
    """ISO YYYY-MM-DD → DD/MM/YYYY (the form's display format)."""
    return date_cls.fromisoformat(iso_date).strftime("%d/%m/%Y")


# ── generic table parser ───────────────────────────────────────
async def _parse_table_in_widget(page: Page, widget_div_id: str) -> dict[str, Any]:
    """Find the data <table> inside the widget div, return {headers, rows}.

    DataTables wraps each datatable in a header-only sibling <table>; the real
    data table is the one with id=<something>. We prefer table[id], fall back
    to the first <table> if no id-tagged table exists.
    """
    widget = page.locator(f"#{widget_div_id}")
    if await widget.count() == 0:
        return {"_error": f"widget div #{widget_div_id} not on page"}

    # Prefer an id-tagged table (the real data table) over the wrapper.
    table = widget.locator("table[id]").first
    if await table.count() == 0:
        table = widget.locator("table").first
    if await table.count() == 0:
        inner = await widget.inner_html()
        return {
            "_error": "no <table> in widget",
            "_inner_html_len": len(inner),
            "_inner_html_preview": inner[:400],
        }

    table_id = await table.get_attribute("id")

    # Headers — DataTables splits the visible header into a sibling wrapper
    # table; its <th> elements carry aria-controls="<data_table_id>". The data
    # table's own thead has empty <th>s. Try aria-controls first, fall back to
    # text_content on thead th (works even if rendering is non-visible).
    headers: list[str] = []
    if table_id:
        for th in await widget.locator(f'th[aria-controls="{table_id}"]').all():
            txt = (await th.text_content()) or ""
            headers.append(re.sub(r"\s+", " ", txt).strip())
    if not headers or all(not h for h in headers):
        # fallback: read from the data table's own thead
        raw = await table.locator("thead th").all_text_contents()
        headers = [re.sub(r"\s+", " ", h).strip() for h in raw]
    headers_clean = headers if (headers and all(headers) and len(set(headers)) == len(headers)) else []

    rows: list[dict[str, Any]] = []
    for tr in await table.locator("tbody tr").all():
        cells_raw = await tr.locator("td").all_text_contents()
        cells = [re.sub(r"\s+", " ", c).strip() for c in cells_raw]
        if not cells or all(not c for c in cells):
            continue
        row: dict[str, Any] = {"cells": cells}
        if headers_clean and len(cells) == len(headers_clean):
            row["by_header"] = dict(zip(headers_clean, cells))
        first_span = tr.locator("td span[title]").first
        if await first_span.count():
            title = await first_span.get_attribute("title")
            if title:
                m = re.match(r"\[(\d+)\]\s*(.*)", title)
                if m:
                    row["totaliser_id"] = int(m.group(1))
                    row["label"] = m.group(2).strip()
        rows.append(row)

    return {
        "table_id": table_id,
        "headers": headers,
        "row_count": len(rows),
        "rows": rows,
    }


async def _load_widget(page: Page, widget_div_id: str, *, timeout_ms: int = 20000) -> bool:
    """Scroll the widget into view + wait for its parent div's data-loaded=true.

    Returns True if the widget reports loaded, False on timeout. Most widgets
    have parent attr `data-widget-name="<div_id>"` and toggle `data-loaded`
    when their AJAX completes.
    """
    parent_sel = f'div.widget[data-widget-name="{widget_div_id}"]'
    parent = page.locator(parent_sel)
    if await parent.count() == 0:
        # Fall back to scrolling the inner div directly.
        await page.locator(f"#{widget_div_id}").scroll_into_view_if_needed()
        return True
    await parent.scroll_into_view_if_needed()
    try:
        await page.wait_for_selector(
            f'{parent_sel}[data-loaded="true"]', timeout=timeout_ms,
        )
        # DataTables finishes rendering a beat after data-loaded flips.
        await page.wait_for_timeout(400)
        return True
    except Exception:
        return False


# ── orchestrator ───────────────────────────────────────────────
async def scrape(
    username: str,
    password: str,
    report_date: str,
    *,
    site: str = "malthouse",
    snapshot_dir: Path = Path("/host-tmp"),
    headless: bool = True,
) -> dict[str, Any]:
    if site not in SITES:
        raise ValueError(f"unknown site '{site}' — expected one of {list(SITES)}")

    snapshot_dir.mkdir(parents=True, exist_ok=True)
    site_info = SITES[site]
    uk_date = _uk_date(report_date)

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=headless,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
        )
        ctx = await browser.new_context()
        page = await ctx.new_page()
        try:
            # ── 1. Login ──
            log.info("touchoffice: login as %s", username)
            await page.goto(BASE_URL + "/", wait_until="domcontentloaded")
            await page.fill("#username", username)
            await page.fill("#password", password)
            await page.click('button[name="submit-login"]')
            await page.wait_for_load_state("networkidle", timeout=30000)

            # ── 2. Select site via Select2 (the underlying <select> is hidden;
            #     setting .value + firing jQuery 'change' triggers Select2).
            #     Changing site triggers a full page reload — we land back on
            #     the home page with the new site in session context. ──
            log.info("touchoffice: select site %s (value=%s)", site, site_info["value"])
            try:
                await page.evaluate(
                    """(value) => {
                        const sel = document.querySelector('#site');
                        if (!sel) return;
                        sel.value = value;
                        sel.dispatchEvent(new Event('change', {bubbles: true}));
                        if (window.jQuery) window.jQuery(sel).trigger('change');
                    }""",
                    site_info["value"],
                )
            except Exception as e:
                log.info("touchoffice: site-change evaluate raised (expected on nav): %s", e)
            # Whether or not a navigation happened, navigate fresh to the home
            # page so subsequent evaluates run in a stable context with the
            # new site session.
            await page.goto(BASE_URL + "/", wait_until="domcontentloaded")
            await page.wait_for_selector("#filter", timeout=15000)
            try:
                await page.wait_for_load_state("networkidle", timeout=10000)
            except Exception:
                pass

            # ── 3. Set dates in the #filter form ──
            log.info("touchoffice: filter date %s", uk_date)
            await page.evaluate(
                """({uk, iso}) => {
                    const set = (sel, v) => {
                        const el = document.querySelector(sel);
                        if (!el) return;
                        el.value = v;
                        el.dispatchEvent(new Event('change', {bubbles: true}));
                    };
                    set('#dateselect-start', uk);
                    set('#dateselect-end',   uk);
                    document.querySelectorAll('input[name="startdate"]').forEach(e => e.value = iso);
                    document.querySelectorAll('input[name="enddate"]').forEach(e => e.value = iso);
                }""",
                {"uk": uk_date, "iso": report_date},
            )

            # ── 4. Submit filter ──
            log.info("touchoffice: submit filter")
            await page.click('button[name="submit-filter"]')
            try:
                await page.wait_for_load_state("networkidle", timeout=30000)
            except Exception:
                pass
            await page.wait_for_timeout(1000)

            # ── 4b. Lazy-load each target widget (scroll into view, wait for
            #     data-loaded="true"). Widgets below the fold don't fetch until
            #     visible. ──
            for widget_key, widget in WIDGETS.items():
                loaded = await _load_widget(page, widget["div_id"])
                log.info(
                    "touchoffice: widget %s loaded=%s", widget_key, loaded,
                )

            # ── 5. Snapshot post-filter (always, for selector-drift diagnostics) ──
            snap_html = snapshot_dir / f"touchoffice-{site}-{report_date}.html"
            snap_png  = snapshot_dir / f"touchoffice-{site}-{report_date}.png"
            snap_html.write_text(await page.content())
            await page.screenshot(path=str(snap_png), full_page=True)

            # ── 6. Extract the three widgets ──
            result: dict[str, Any] = {
                "report_type": "touchoffice_home_widgets",
                "report_date": report_date,
                "report_date_display": uk_date,
                "site": site,
                "site_label": site_info["label"],
                "site_kind": site_info["kind"],
                "_snapshot_html": str(snap_html),
                "_snapshot_png":  str(snap_png),
            }
            for widget_key, widget in WIDGETS.items():
                log.info("touchoffice: extracting %s", widget_key)
                result[widget_key] = await _parse_table_in_widget(page, widget["div_id"])

            return result
        finally:
            await browser.close()
