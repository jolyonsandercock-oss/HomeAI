"""ocr/mistral_ocr.py — Mistral OCR API.

Vault-gated: activates only when secret/mistral-ocr exists in Vault with
field `api_key` (it does not exist yet — this module must stay fully
importable/testable without it, and start working the moment the secret is
written; no code change or restart required). Mistral OCR (released Mar
2025) outputs markdown + structured tables; ~95% field accuracy on
receipts/invoices benchmarks at ~$0.001/page — cheapest premium option in
our adapter set.

Useful tier when accuracy matters but Azure DI is overkill (e.g.
non-standard receipt formats from cash sales).

Not wired into the live pipeline yet — that's a future sprint.

PII / EGRESS SCOPE — READ BEFORE WIRING IN
===========================================
This adapter sends the *raw document bytes* to a third-party API
(api.mistral.ai). Until the outbound-data egress decision is made (see
n8n-decision-for-gpt55-review.md-adjacent egress work / Hermes DeepSeek
redaction gap), this engine is authorized for **supplier invoices only**.
Do NOT route bank statements, mortgage documents, or any personal/family
document through it — see MISTRAL_OCR_ALLOWED_KINDS below.

registry.select() and every current call site pass only `file_path` into
`extract()` (see ocr/base.py's OCRAdapter Protocol) — `documents.category`
("invoice" | "bank_statement" | "mortgage" | ... — see
postgres/migrations/V248__pipeline_drift_view.sql) is NOT threaded through
to the adapter today. That means this scope constraint CANNOT be
code-enforced at the call boundary yet.
  TODO(egress-decision): once a document kind/category is threaded into
  the extract() call path, wire the enforcement check that already exists
  below (the `doc_kind` guard) so it runs on every call, not just when a
  caller opts in.
Until then: any code that selects this engine (via system_state
`ocr.engine` or by constructing MistralOCRAdapter directly) MUST self-police
and only call extract() for documents.category='invoice' rows.
"""
from __future__ import annotations

import base64
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    from .base import OCRAdapter, OCRResult
except ImportError:
    # Allow `python3 scripts/ocr/mistral_ocr.py --selftest ...` (no package
    # context) in addition to normal package import.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from base import OCRAdapter, OCRResult  # type: ignore[no-redef]

# Document categories this engine is currently authorized to process. Keep
# in sync with the PII/EGRESS SCOPE note above — do not widen without
# resolving the egress decision first.
MISTRAL_OCR_ALLOWED_KINDS = frozenset({"invoice"})

# Retry protocol mirrors the repo convention documented in lib/README.md
# (retry 408/409/429/5xx/529 with growing backoff) — Mistral isn't
# Anthropic so lib/claude_call.py itself doesn't apply, but the same
# retryable-status set and exponential-backoff shape are reused here, per
# scripts/u151b-reocr-vision.py.
_RETRYABLE_STATUSES = {408, 409, 429, 500, 502, 503, 504, 529}
_MAX_ATTEMPTS = 5
_REQUEST_TIMEOUT_S = 120
_DEFAULT_MODEL = "mistral-ocr-latest"


class MistralOCRAdapter:
    name = "mistral_ocr"
    API_ROOT = "https://api.mistral.ai/v1"

    def __init__(self, api_key: str, model: str = _DEFAULT_MODEL):
        self.api_key = api_key
        self.model = model

    @classmethod
    def from_vault(cls, vault_client) -> "MistralOCRAdapter | None":
        try:
            secret = vault_client.read("mistral-ocr")
        except Exception:
            # Vault down/sealed/unreachable is not our problem to raise —
            # same "unavailable, fall through" contract as "no key".
            return None
        if not secret or not secret.get("api_key"):
            return None
        return cls(secret["api_key"], model=secret.get("model") or _DEFAULT_MODEL)

    def extract(self, file_path: Path, doc_kind: str | None = None) -> OCRResult:
        """OCR file_path via the Mistral OCR API, returning page-concatenated
        markdown text.

        `doc_kind` is optional (no current call site passes it — see module
        docstring TODO) but if a caller does pass it, it is enforced against
        MISTRAL_OCR_ALLOWED_KINDS immediately: this is the enforcement hook
        future wiring should call into.
        """
        if doc_kind is not None and doc_kind not in MISTRAL_OCR_ALLOWED_KINDS:
            raise ValueError(
                f"MistralOCRAdapter is scoped to {sorted(MISTRAL_OCR_ALLOWED_KINDS)} "
                f"until the egress decision lands; refusing doc_kind={doc_kind!r}"
            )

        file_path = Path(file_path)
        data = file_path.read_bytes()
        mime = mimetypes.guess_type(str(file_path))[0] or "application/pdf"
        b64 = base64.b64encode(data).decode("ascii")

        payload = {
            "model": self.model,
            "document": {
                "type": "document_url",
                "document_url": f"data:{mime};base64,{b64}",
            },
            "include_image_base64": False,
        }
        resp = self._post_with_retry("/ocr", payload)

        pages = resp.get("pages") or []
        text = "\n\n".join(p.get("markdown", "") for p in pages)

        return OCRResult(
            text=text,
            confidence=-1.0,  # Mistral OCR API doesn't return a confidence score
            engine=self.name,
            raw=resp,
        )

    def healthcheck(self) -> bool:
        return bool(self.api_key)

    def _post_with_retry(self, path: str, payload: dict) -> dict:
        url = f"{self.API_ROOT}{path}"
        body = json.dumps(payload).encode("utf-8")
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }
        last_err: Exception | None = None
        for attempt in range(_MAX_ATTEMPTS):
            req = urllib.request.Request(url, data=body, method="POST", headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=_REQUEST_TIMEOUT_S) as r:
                    return json.loads(r.read())
            except urllib.error.HTTPError as e:
                last_err = e
                if e.code in _RETRYABLE_STATUSES and attempt < _MAX_ATTEMPTS - 1:
                    backoff = min(60, 2 ** attempt * 5)  # 5, 10, 20, 40, 60s
                    print(
                        f"    [mistral_ocr] HTTP {e.code} — attempt "
                        f"{attempt + 1}/{_MAX_ATTEMPTS}, backing off {backoff}s",
                        file=sys.stderr,
                    )
                    time.sleep(backoff)
                    continue
                detail = e.read()[:300]
                raise RuntimeError(f"Mistral OCR API error {e.code}: {detail!r}") from e
            except (urllib.error.URLError, TimeoutError) as e:
                last_err = e
                if attempt < _MAX_ATTEMPTS - 1:
                    backoff = min(60, 2 ** attempt * 5)
                    print(
                        f"    [mistral_ocr] {e} — attempt "
                        f"{attempt + 1}/{_MAX_ATTEMPTS}, backing off {backoff}s",
                        file=sys.stderr,
                    )
                    time.sleep(backoff)
                    continue
                raise RuntimeError(f"Mistral OCR API unreachable: {e}") from e
        raise RuntimeError("Mistral OCR API: exhausted retries") from last_err


class _HTTPVaultClient:
    """Minimal read-only Vault client for CLI/selftest use.

    Implements the same `.read(name) -> dict | None` contract that
    `from_vault()` expects, so `python3 mistral_ocr.py --selftest` can
    exercise the real gate without a bespoke test harness. Hits the Vault
    HTTP API directly (KV-v2, secret/<name> mount) rather than shelling out
    to `vault kv get`, mirroring scripts/u286-caterbook-guest-sync.py and
    scripts/bg-lite-harvest.py. Never raises — any failure (no token, vault
    sealed, network error, 404) is treated as "no secret".
    """

    def __init__(self, addr: str | None = None, token: str | None = None):
        self.addr = (addr or os.environ.get("VAULT_ADDR") or "http://vault:8200").rstrip("/")
        self.token = token or os.environ.get("VAULT_TOKEN") or ""

    def read(self, name: str) -> dict | None:
        if not self.token:
            return None
        req = urllib.request.Request(
            f"{self.addr}/v1/secret/data/{name}",
            headers={"X-Vault-Token": self.token},
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                body = json.loads(r.read())
            return body.get("data", {}).get("data")
        except Exception:
            return None


def _selftest(pdf_path: str) -> int:
    adapter = MistralOCRAdapter.from_vault(_HTTPVaultClient())
    if adapter is None:
        print("unavailable (no key)")
        return 3

    result = adapter.extract(Path(pdf_path), doc_kind="invoice")
    page_count = len(result.raw.get("pages") or [])
    print(f"pages: {page_count}")
    print(result.text[:500])
    return 0


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Mistral OCR adapter self-test")
    parser.add_argument(
        "--selftest",
        metavar="PDF_PATH",
        help="OCR the given PDF via the live API (needs secret/mistral-ocr in Vault)",
    )
    args = parser.parse_args()

    if not args.selftest:
        parser.print_help()
        sys.exit(2)

    sys.exit(_selftest(args.selftest))
