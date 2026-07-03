"""MarkItDown microservice — converts non-PDF document formats to markdown.

Sibling to pdfplumber. Pipeline 2 + Pipeline 9 use this for image, Word,
HTML, EPUB, and plain-text invoice/report attachments.

POST /convert      → multipart `file` upload → {"text": "...markdown...", "content_hash": "..."}
GET  /healthcheck  → {"status": "ok"}

Sanitisation: strip control bytes + cap at 16K chars (markdown is denser
than raw text; bigger cap than pdfplumber's 8K).
"""
from __future__ import annotations

import asyncio
import hashlib
import io
import re
import tempfile
import threading
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from markitdown import MarkItDown

MAX_FILE_BYTES = 25 * 1024 * 1024  # 25MB hard cap
MAX_OUTPUT_CHARS = 16_000

app = FastAPI(title="MarkItDown", version="1.0")
md = MarkItDown()
# md is a shared instance and not documented thread-safe; conversions run in
# a worker thread (so the event loop stays responsive — perf pass 2026-07-03)
# but serialised under this lock, matching the old effective concurrency.
_md_lock = threading.Lock()


def _convert_locked(path: str):
    with _md_lock:
        return md.convert(path)


def sanitise(text: str) -> str:
    """Strip control bytes, cap length. Same posture as pdfplumber's sanitise."""
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    return text[:MAX_OUTPUT_CHARS]


@app.post("/convert")
async def convert(file: UploadFile = File(...)):
    content = await file.read()
    if len(content) == 0:
        raise HTTPException(400, "empty file")
    if len(content) > MAX_FILE_BYTES:
        raise HTTPException(413, f"file too large ({len(content)} bytes; max {MAX_FILE_BYTES})")

    # MarkItDown reads from a path — write to a tmpfile preserving suffix
    # so its dispatcher can pick the right converter.
    suffix = Path(file.filename or "upload").suffix or ".bin"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tf:
        tf.write(content)
        tmp_path = tf.name

    try:
        result = await asyncio.to_thread(_convert_locked, tmp_path)
        text = sanitise(result.text_content or "")
    except Exception as e:
        raise HTTPException(422, f"conversion failed: {e}")
    finally:
        try:
            Path(tmp_path).unlink()
        except FileNotFoundError:
            pass

    return {
        "text": text,
        "content_hash": hashlib.sha256(content).hexdigest(),
        "filename": file.filename,
        "size": len(content),
    }


@app.get("/healthcheck")
async def healthcheck():
    return {"status": "ok"}
