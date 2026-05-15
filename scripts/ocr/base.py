"""ocr/base.py — OCR adapter contract.

All adapters return the same OCRResult shape so callers (re-OCR job,
benchmark, the eventual /api/documents/re-ocr endpoint) can swap engines
without code changes. The engine is selected at runtime via:
  1. system_state.value WHERE key='ocr.engine'  (operator-set preference)
  2. presence of a Vault key for that engine    (capability gate)
  3. fallback → tesseract (always available — Paperless does it for free)
"""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass
class OCRResult:
    text: str
    confidence: float  # 0.0–1.0; -1.0 if engine doesn't report
    engine: str        # 'tesseract' | 'azure_di' | 'mistral_ocr'
    raw: dict          # engine-specific raw response (for debug / structured fields)


class OCRAdapter(Protocol):
    name: str

    def extract(self, file_path: Path) -> OCRResult: ...
    def healthcheck(self) -> bool: ...
