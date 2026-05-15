"""ocr/tesseract.py — Tesseract passthrough.

Paperless-ngx already runs Tesseract on every document during consume; the
text lands in documents.ocr_text via our webhook. So this adapter is a
*passthrough* that returns documents.ocr_text for the given paperless_id.

We never re-invoke Tesseract here — that would duplicate work Paperless has
already done. The adapter exists so the registry can return *something*
when no premium engine is configured.
"""
from __future__ import annotations
from pathlib import Path
from .base import OCRAdapter, OCRResult


class TesseractPassthroughAdapter:
    name = "tesseract"

    def __init__(self, doc_row: dict):
        self.doc_row = doc_row

    def extract(self, file_path: Path) -> OCRResult:
        return OCRResult(
            text=self.doc_row.get("ocr_text") or "",
            confidence=-1.0,
            engine=self.name,
            raw={"source": "paperless-tesseract"},
        )

    def healthcheck(self) -> bool:
        return True
