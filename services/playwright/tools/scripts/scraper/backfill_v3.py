#!/usr/bin/env python3
"""TouchOffice backfill v3: single-browser, robust, fast."""
import asyncio, json, hashlib, os, re, sys, time as t_mod
from datetime import date, timedelta
import httpx

BASE_URL = "https://www.touchoffice.net"
SITE_VAL = "1"  # malthouse
PG_DSN = os.environ.get("PG_DSN", "")
VAULT = os.environ.get("VAULT_TOKEN", "")
WINTER = {1, 2}


def daterange(s, e):
    for n in range((e - s).days + 1):
        yield s + timedelta(n)


def is_trading(d):
    return d.weekday() < 5 and d.month not in WINTER


def uk_date(d):
    return d.strftime("%d/%m/%Y")


def _ikey(*parts):
    return f"to_{hashlib.sha256('|'.join(str(p) for p in parts).encode()).hexdigest()[:24]}"


def _num(s):
    if not s:
        return None
    m = re.search(r"[\d,.]+(?:\.[\d]{2})?", s)
    if not m:
        return None
    return float(m.group().replace(",", ""))


async def dismiss_dialogs(page):
    """Dismiss any dialog overlays that might intercept clicks."""
    try:
        await page.evaluate("""() => {
            const overlays = document.querySelectorAll('.ui-widget-overlay, .ui-dialog, .modal, .modal-backdrop');
            overlays.forEach(el => { if (el && el.parentNode) el.parentNode.removeChild(el); });
            // Also remove any visible dialog containers
            const dlg = document.getElementById('dialog-container');
            if (dlg) dlg.style.display = 'none';
        }""")
    except Exception:
        pass


async def scrape_one_date(page, creds, rd, ctx=None):
    """Scrape a single date and return parsed data dict."""
    ds = rd.isoformat()
    uk = uk_date(rd)
    _ = ctx  # unused, kept for signature compat

    # Navigate to root (re-login if session expired)
    await page.goto(BASE_URL + "/", wait_until="domcontentloaded", timeout=30000)

    # Check if we need to login
    login_btn = page.locator('button[name="submit-login"]')
    if await login_btn.count() > 0 and await login_btn.is_visible():
        await page.fill("#username", creds["username"], timeout=10000)
        await page.fill("#password", creds["password"], timeout=10000)
        await login_btn.click()
        await page.wait_for_timeout(3000)

    # Set site (Select2 widget — click the container then pick option)
    await dismiss_dialogs(page)
    try:
        # Click the Select2 container to open it
        sel2 = page.locator(".select2-selection--single")
        if await sel2.count() > 0 and await sel2.is_visible():
            await sel2.click(timeout=5000)
            await page.wait_for_timeout(500)
            # Then use JS to select
            await page.evaluate(
                """(v) => {
                    const sel = document.querySelector('#site');
                    if (sel) { sel.value = v; sel.dispatchEvent(new Event('change', {bubbles: true})); }
                }""",
                SITE_VAL,
            )
            await page.wait_for_timeout(1000)
            # Close the container by clicking elsewhere
            await page.evaluate("""() => {
                const s = document.querySelector('.select2-container--open');
                if (s) s.style.display = 'none';
            }""")
        else:
            # Fallback: try native select
            site_sel = page.locator("#site")
            if await site_sel.count() > 0:
                await site_sel.select_option(SITE_VAL, timeout=5000)
    except Exception:
        # Last resort JS-only
        await page.evaluate(
            """(v) => {
                const sel = document.querySelector('#site');
                if (sel) { sel.value = v; sel.dispatchEvent(new Event('change', {bubbles: true})); }
            }""",
            SITE_VAL,
        )
    await page.wait_for_timeout(1000)

    await page.goto(BASE_URL + "/", wait_until="domcontentloaded", timeout=30000)

    # Wait for filter
    try:
        await page.wait_for_selector("#filter", timeout=15000)
    except Exception:
        await page.goto(BASE_URL + "/", wait_until="domcontentloaded", timeout=30000)
        await page.wait_for_selector("#filter", timeout=15000)

    await dismiss_dialogs(page)

    # Set dates via JS (more reliable than fill)
    await page.evaluate(
        """({uk, iso}) => {
            const setVal = (sel, v) => {
                const el = document.querySelector(sel);
                if (el) { el.value = v; el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true})); }
            };
            setVal('#dateselect-start', uk);
            setVal('#dateselect-end', uk);
            document.querySelectorAll('input[name="startdate"]').forEach(e => { e.value = iso; });
            document.querySelectorAll('input[name="enddate"]').forEach(e => { e.value = iso; });
        }""",
        {"uk": uk, "iso": ds},
    )

    # Submit filter - try various selectors
    await dismiss_dialogs(page)
    submit_btn = page.locator('button[name="submit-filter"]')
    if await submit_btn.count() > 0:
        await submit_btn.click()
    else:
        # Try the filter form submit directly
        await page.evaluate("""() => {
            const f = document.getElementById('filter') || document.querySelector('form');
            if (f) f.submit();
        }""")
    await page.wait_for_timeout(3000)

    # Quick check for data tables - don't wait long
    await dismiss_dialogs(page)
    try:
        await page.wait_for_function(
            "() => document.querySelector('#fixed_totals table') !== null || document.querySelector('.ui-tabs-panel[aria-hidden=false] table') !== null",
            timeout=5000,
        )
    except Exception:
        pass  # If no data, that's ok — may be empty date

    # Parse widgets
    async def parse_widget(wid):
        try:
            w = page.locator(f"#{wid}")
            if await w.count() == 0:
                return []
            table = w.locator("table[id]").first
            if await table.count() == 0:
                return []
            rows = table.locator("tbody tr")
            count = await rows.count()
            result = []
            for i in range(count):
                cells = rows.nth(i).locator("td")
                cc = await cells.count()
                result.append(
                    {
                        "cells": [
                            (await cells.nth(j).text_content() or "").strip()
                            for j in range(cc)
                        ]
                    }
                )
            return result
        except Exception:
            return []

    ft_rows = await parse_widget("fixed_totals")
    ds_rows = await parse_widget("department_sales_total")
    plu_rows = await parse_widget("plu_sales")

    # Enrich fixed totals
    ft_enriched = []
    for r in ft_rows:
        cells = r["cells"]
        label = cells[0].strip() if cells else ""
        ft_enriched.append(
            {
                "cells": cells,
                "label": label,
                "totaliser_id": hash(label + ds) % 1000000,
            }
        )

    return {
        "fixed_totals": {"rows": ft_enriched, "row_count": len(ft_enriched)},
        "department_sales_total": {"rows": ds_rows, "row_count": len(ds_rows)},
        "plu_sales": {"rows": plu_rows, "row_count": len(plu_rows)},
    }


async def ingest_result(pool, rd, result):
    """Write scraped data to PostgreSQL."""
    from playwright.async_api import async_playwright
    import asyncpg

    ds = rd.isoformat()
    site_name = "malthouse"

    ft_enriched = result["fixed_totals"]["rows"]
    ds_rows = result["department_sales_total"]["rows"]
    plu_rows = result["plu_sales"]["rows"]

    async with pool.acquire() as conn:
        await conn.execute("SET LOCAL app.current_entity = '1'")
        await conn.execute("SET LOCAL app.current_realm = 'work'")

        for row in ft_enriched:
            cells = row["cells"]
            if len(cells) >= 3:
                try:
                    await conn.execute(
                        """INSERT INTO touchoffice_fixed_totals
                           (idempotency_key, site, report_date, totaliser_id, label, quantity, value, raw_cells)
                           VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
                           ON CONFLICT (site, report_date, totaliser_id) DO UPDATE
                           SET label=EXCLUDED.label, quantity=EXCLUDED.quantity, value=EXCLUDED.value""",
                        _ikey("ft", site_name, ds, row.get("totaliser_id")),
                        site_name,
                        rd,
                        row.get("totaliser_id"),
                        row.get("label", ""),
                        _num(cells[1]) if len(cells) > 1 else None,
                        _num(cells[2]) if len(cells) > 2 else None,
                        json.dumps(cells),
                    )
                except Exception as e:
                    print(f"      [WARN] ft row: {e}", flush=True)

        for row in ds_rows:
            cells = row["cells"]
            if len(cells) >= 3:
                try:
                    await conn.execute(
                        """INSERT INTO touchoffice_department_sales
                           (idempotency_key, site, report_date, department, quantity, value, raw_cells)
                           VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb)
                           ON CONFLICT (site, report_date, department) DO UPDATE
                           SET quantity=EXCLUDED.quantity, value=EXCLUDED.value""",
                        _ikey("ds", site_name, ds, cells[0]),
                        site_name,
                        rd,
                        cells[0],
                        _num(cells[1]) if len(cells) > 1 else None,
                        _num(cells[2]) if len(cells) > 2 else None,
                        json.dumps(cells),
                    )
                except Exception as e:
                    print(f"      [WARN] ds row: {e}", flush=True)

        for row in plu_rows:
            cells = row["cells"]
            if len(cells) >= 4:
                try:
                    await conn.execute(
                        """INSERT INTO touchoffice_plu_sales
                           (idempotency_key, site, report_date, plu_number, descriptor, quantity, value, raw_cells)
                           VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
                           ON CONFLICT (site, report_date, plu_number) DO UPDATE
                           SET descriptor=EXCLUDED.descriptor, quantity=EXCLUDED.quantity, value=EXCLUDED.value""",
                        _ikey("plu", site_name, ds, cells[0]),
                        site_name,
                        rd,
                        cells[0],
                        cells[1] if len(cells) > 1 else "",
                        _num(cells[2]) if len(cells) > 2 else None,
                        _num(cells[3]) if len(cells) > 3 else None,
                        json.dumps(cells),
                    )
                except Exception as e:
                    print(f"      [WARN] plu row: {e}", flush=True)

    # Report net
    net = ""
    for r in ft_enriched:
        if "NET" in str(r.get("cells", [])):
            c = r.get("cells", [])
            net = c[2] if len(c) > 2 else ""
            break

    return {"ft": len(ft_enriched), "ds": len(ds_rows), "plu": len(plu_rows), "net": net}


async def main():
    import argparse
    import asyncpg

    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="from_date", default="2021-01-01")
    parser.add_argument("--to", dest="to_date", default="2025-05-12")
    args = parser.parse_args()

    start = date.fromisoformat(args.from_date)
    end = date.fromisoformat(args.to_date)

    # Get existing dates
    pool = await asyncpg.create_pool(PG_DSN, min_size=1, max_size=2)
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT DISTINCT report_date FROM touchoffice_fixed_totals WHERE site='malthouse'"
        )
    existing = {r["report_date"] for r in rows}

    all_dates = [d for d in daterange(start, end) if is_trading(d)]
    to_scrape = [d for d in all_dates if d not in existing]

    print(f"Existing: {len(existing)} dates in DB", flush=True)
    print(f"Target: {start} to {end}", flush=True)
    print(f"Trading: {len(all_dates)}", flush=True)
    print(f"To do: {len(to_scrape)}", flush=True)
    print(f"Est: ~{len(to_scrape)*5//60}min", flush=True)
    print("Starting...", flush=True)

    # Get credentials
    async with httpx.AsyncClient() as c:
        r = await c.get(
            "http://vault:8200/v1/secret/data/touchoffice",
            headers={"X-Vault-Token": VAULT},
        )
        creds = r.json()["data"]["data"]

    # Single browser for all dates
    from playwright.async_api import async_playwright

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(
            headless=True, args=["--no-sandbox", "--disable-setuid-sandbox"]
        )
        ctx = await browser.new_context(
            viewport={"width": 1920, "height": 1080},
            ignore_https_errors=True,
        )
        page = await ctx.new_page()
        page.set_default_timeout(45000)

        t_start = t_mod.monotonic()
        ok = fail = 0

        for i, d in enumerate(to_scrape):
            ds = d.isoformat()
            t0 = t_mod.monotonic()
            try:
                result = await asyncio.wait_for(
                    scrape_one_date(page, creds, d, ctx), timeout=120
                )
                r = await asyncio.wait_for(
                    ingest_result(pool, d, result), timeout=30
                )
                elapsed = t_mod.monotonic() - t0
                print(
                    f"[{i+1:4d}/{len(to_scrape)}] {ds} ft={r['ft']} ds={r['ds']} plu={r['plu']} NET={r['net']} ({elapsed:.0f}s)",
                    flush=True,
                )
                ok += 1
            except asyncio.TimeoutError:
                elapsed = t_mod.monotonic() - t0
                print(
                    f"[{i+1:4d}/{len(to_scrape)}] {ds} TIMEOUT ({elapsed:.0f}s)",
                    flush=True,
                )
                fail += 1
                if fail > 10:
                    print("Too many failures, aborting", flush=True)
                    break
                # Re-create page after timeout (browser might be stale)
                try:
                    await page.close()
                except Exception:
                    pass
                page = await ctx.new_page()
                page.set_default_timeout(45000)
            except Exception as e:
                elapsed = t_mod.monotonic() - t0
                print(
                    f"[{i+1:4d}/{len(to_scrape)}] {ds} FAIL: {str(e)[:200]} ({elapsed:.0f}s)",
                    flush=True,
                )
                fail += 1
                if fail > 10:
                    print("Too many failures, aborting", flush=True)
                    break
                # Re-create page after error
                try:
                    await page.close()
                except Exception:
                    pass
                page = await ctx.new_page()
                page.set_default_timeout(45000)

            # Progress every 50
            if (i + 1) % 50 == 0:
                et = t_mod.monotonic() - t_start
                rate = (i + 1) / et
                left = (len(to_scrape) - i - 1) / rate / 60
                print(
                    f"--- {i+1}/{len(to_scrape)} done, {et/60:.0f}min elapsed, {left:.0f}min left ---",
                    flush=True,
                )

        await browser.close()

    await pool.close()
    et = t_mod.monotonic() - t_start
    print(f"\n=== DONE ===", flush=True)
    print(f"OK: {ok}  Fail: {fail}", flush=True)
    print(f"Time: {et:.0f}s ({et/60:.0f}min)", flush=True)


asyncio.run(main())
