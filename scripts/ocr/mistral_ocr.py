"""ocr/mistral_ocr.py — Mistral OCR API.

SKELETON. Activates only when secret/mistral-ocr exists in Vault with
field `api_key`. Mistral OCR (released Mar 2025) outputs markdown +
structured tables; ~95% field accuracy on receipts/invoices benchmarks
at ~$0.001/page — cheapest premium option in our adapter set.

Useful tier when accuracy matters but Azure DI is overkill (e.g.
non-standard receipt formats from cash sales).

Not wired into the live pipeline yet — that's a future sprint.
"""
from __future__ import annotations
from pathlib import Path
from .base import OCRAdapter, OCRResult


class MistralOCRAdapter:
    name = "mistral_ocr"
    API_ROOT = "https://api.mistral.ai/v1"

    def __init__(self, api_key: str):
        self.api_key = api_key

    @classmethod
    def from_vault(cls, vault_client) -> "MistralOCRAdapter | None":
        secret = vault_client.read("mistral-ocr")
        if not secret or not secret.get("api_key"):
            return None
        return cls(secret["api_key"])

    def extract(self, file_path: Path) -> OCRResult:
        # Stub. Real impl: POST /v1/ocr with multipart file + bearer token,
        # parse {"text": ..., "pages": [...]} response, return.
        raise NotImplementedError(
            "MistralOCRAdapter.extract is a skeleton; wire HTTP client when activating"
        )

    def healthcheck(self) -> bool:
        return bool(self.api_key)
