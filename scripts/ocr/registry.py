"""ocr/registry.py — adapter selection.

select(doc_row, vault_client, conn) → OCRAdapter
  1. Read system_state[ocr.engine] (operator preference, default 'tesseract')
  2. Try to instantiate that engine via Vault. If creds absent → fall through.
  3. Fallback order: azure_di → mistral_ocr → tesseract (always wins).

This is intentionally Vault-gated rather than env-gated so adding a new
provider is a `vault kv put` operation; no compose changes required.
"""
from __future__ import annotations
from .base       import OCRAdapter
from .tesseract  import TesseractPassthroughAdapter
from .azure_di   import AzureDIAdapter
from .mistral_ocr import MistralOCRAdapter


def select(doc_row: dict, vault_client, conn=None) -> OCRAdapter:
    preferred = _read_state(conn) if conn else "tesseract"

    builders = {
        "azure_di":    lambda: AzureDIAdapter.from_vault(vault_client),
        "mistral_ocr": lambda: MistralOCRAdapter.from_vault(vault_client),
    }
    if preferred in builders:
        a = builders[preferred]()
        if a:
            return a
    # Fallback chain — first available premium, else tesseract.
    for name in ("azure_di", "mistral_ocr"):
        if name == preferred:
            continue
        if name in builders:
            a = builders[name]()
            if a:
                return a
    return TesseractPassthroughAdapter(doc_row)


def _read_state(conn) -> str:
    row = conn.fetchrow("SELECT value FROM system_state WHERE key='ocr.engine'")
    return (row["value"] if row else "tesseract") or "tesseract"
