"""Shared debug-dump helper for Playwright scrapers.

When a scraper hits an unfamiliar screen (selector miss, unexpected URL,
2FA chooser not found) it calls dump_state() to drop:

  <name>-<ts>.png    screenshot of the current page
  <name>-<ts>.html   page.content() — the rendered DOM
  <name>-<ts>.json   url, title, viewport, cookie count, and the reason

Files land in /home_ai/storage/scraper-debug/ which is bind-mounted from
the host (per docker-compose.yml), so you can read them from outside the
container without `docker cp`.

Best-effort: any error inside the dump is logged and swallowed — debug
collection must never break a scrape.
"""
from __future__ import annotations

import datetime as _dt
import json
import logging
import os
from pathlib import Path
from typing import Any

from playwright.async_api import Page  # type: ignore

log = logging.getLogger(__name__)

DEBUG_DIR = Path(os.environ.get(
    "SCRAPER_DEBUG_DIR", "/host-tmp"))   # /host-tmp ↔ /home_ai/storage/scraper-debug

# How many dump-sets to keep per scraper name. Older ones get deleted on
# each new dump to stop /host-tmp filling indefinitely.
KEEP_PER_SCRAPER = 30


async def dump_state(page: Page, name: str, reason: str, **extra: Any) -> Path | None:
    """Drop screenshot + HTML + meta-JSON for a Playwright page.

    Returns the directory the files were written to (so the caller can
    log it for me to grep against). Returns None on hard failure — but
    the caller should never branch on the return value, only use it for
    log messages.
    """
    try:
        DEBUG_DIR.mkdir(parents=True, exist_ok=True)
        ts = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        stem = f"{name}-{ts}"
        png_path  = DEBUG_DIR / f"{stem}.png"
        html_path = DEBUG_DIR / f"{stem}.html"
        meta_path = DEBUG_DIR / f"{stem}.json"

        # Screenshot first — visual is the most useful artifact.
        try:
            await page.screenshot(path=str(png_path), full_page=True)
        except Exception as e:
            log.warning("debug: screenshot failed for %s: %s", name, e)
            png_path = None  # type: ignore[assignment]

        # HTML
        try:
            html = await page.content()
            html_path.write_text(html, encoding="utf-8")
        except Exception as e:
            log.warning("debug: page.content() failed for %s: %s", name, e)
            html_path = None  # type: ignore[assignment]

        # Meta
        meta: dict[str, Any] = {
            "name":     name,
            "reason":   reason,
            "url":      page.url,
            "timestamp": ts,
        }
        try:
            meta["title"] = await page.title()
        except Exception:
            pass
        try:
            vp = page.viewport_size
            if vp:
                meta["viewport"] = vp
        except Exception:
            pass
        try:
            ctx = page.context
            cookies = await ctx.cookies()
            meta["cookie_count"] = len(cookies)
            meta["cookie_domains"] = sorted({c.get("domain", "") for c in cookies})
        except Exception:
            pass
        meta.update(extra)
        try:
            meta_path.write_text(
                json.dumps(meta, indent=2, default=str), encoding="utf-8")
        except Exception as e:
            log.warning("debug: meta write failed for %s: %s", name, e)

        log.warning(
            "debug: dumped state for %s (%s) → %s/%s.{png,html,json}",
            name, reason, DEBUG_DIR, stem,
        )

        _prune_old(name)
        return DEBUG_DIR
    except Exception as e:
        log.warning("debug: dump_state crashed for %s: %s", name, e)
        return None


def _prune_old(name: str) -> None:
    """Keep only KEEP_PER_SCRAPER recent dump-sets per scraper name."""
    try:
        # Group by stem (name-ts); each stem has up to 3 files.
        stems: dict[str, list[Path]] = {}
        for p in DEBUG_DIR.glob(f"{name}-*.*"):
            stem = p.stem  # e.g. dojo-20260529-160100
            stems.setdefault(stem, []).append(p)
        if len(stems) <= KEEP_PER_SCRAPER:
            return
        oldest_first = sorted(stems.keys())  # ts is in the stem → lexicographic sort works
        for stem in oldest_first[:-KEEP_PER_SCRAPER]:
            for p in stems[stem]:
                try:
                    p.unlink()
                except Exception:
                    pass
    except Exception as e:
        log.warning("debug: prune failed for %s: %s", name, e)
