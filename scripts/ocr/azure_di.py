"""ocr/azure_di.py — Azure Document Intelligence (prebuilt-invoice).

SKELETON. Activates only when secret/azure-di exists in Vault with fields
`endpoint` and `key`. The prebuilt-invoice model returns structured
invoice fields (vendor, total, line items) in addition to OCR text — so
when this engine is selected, future Haiku line-extractor work becomes a
verifier rather than the primary extractor.

Pricing (as of 2026-04): $10/1000 pages for prebuilt-invoice tier; ~98%
field-level accuracy on UK invoices in Microsoft's own bench. Drop-in
replacement when invoice volume justifies the spend (>200 invoices/month
breaks even vs. Haiku 4.5 input tokens).

Not wired into the live pipeline yet — that's a future sprint.
"""
from __future__ import annotations
from pathlib import Path
from .base import OCRAdapter, OCRResult


class AzureDIAdapter:
    name = "azure_di"

    def __init__(self, endpoint: str, key: str):
        self.endpoint = endpoint.rstrip("/")
        self.key      = key

    @classmethod
    def from_vault(cls, vault_client) -> "AzureDIAdapter | None":
        secret = vault_client.read("azure-di")
        if not secret or not secret.get("endpoint") or not secret.get("key"):
            return None
        return cls(secret["endpoint"], secret["key"])

    def extract(self, file_path: Path) -> OCRResult:
        # Stub. Real impl: POST to /formrecognizer/documentModels/
        # prebuilt-invoice:analyze?api-version=2024-07-31 with file bytes,
        # poll the operation-location URL, return structured response.
        raise NotImplementedError(
            "AzureDIAdapter.extract is a skeleton; wire HTTP client when activating"
        )

    def healthcheck(self) -> bool:
        return bool(self.endpoint and self.key)
