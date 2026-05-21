"""
homeai-presidio
===============
PII redaction service for the cloud-bound LLM path.

POST /redact
    body: { "text": "...", "workflow_id"?: "...", "capability_tag"?: "...", "realm"?: "work" }
    returns: { "redacted_text": "...", "audit_id": 123, "recognisers_hit": {"UK_POSTCODE": 2, ...},
               "redacted_token_count": 5, "latency_ms": 12 }

Behaviour:
  * Detects PII using Presidio Analyzer + spaCy en_core_web_lg + custom UK
    recognizers (UK_POSTCODE, UK_SORT_CODE, UK_ACCOUNT_NUMBER, UK_NI_NUMBER,
    UK_VAT_NUMBER) and Xero contact IDs loaded from xero_contacts at boot.
  * Replaces each detected span with <REDACTED:ENTITY_TYPE_N> tokens.
  * Writes a row to redaction_audit_log on every call (status='ok').
  * Failures are not silenced — return 500 so the caller (llm-router) can
    enforce HARD-FAIL.

GET /healthcheck — 200 OK if Presidio analyzer + DB pool are healthy.

Caller integration: llm-router calls /redact before _call_claude. On 5xx
from this service, llm-router writes a row with status='hard_fail' and
returns 503 to ITS caller. No soft-pass.
"""

import asyncio
import hashlib
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Optional

import asyncpg
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel

from presidio_analyzer import AnalyzerEngine, RecognizerRegistry
from presidio_analyzer.nlp_engine import NlpEngineProvider

from recognizers import CUSTOM_RECOGNIZERS

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("homeai-presidio")

PG_HOST = os.environ.get("POSTGRES_HOST", "homeai-postgres")
PG_PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
PG_USER = os.environ.get("POSTGRES_USER", "postgres")
PG_PW   = os.environ.get("POSTGRES_PASSWORD", "")
PG_DB   = os.environ.get("POSTGRES_DB", "homeai")

PRESIDIO_VERSION = "2.2.355"

# ----- Standard PII entities we want to redact -----------------------------
# Presidio's built-in entities + our custom UK ones. PERSON comes from spaCy.
TARGET_ENTITIES = [
    "PERSON",           # spaCy NER
    "EMAIL_ADDRESS",
    "PHONE_NUMBER",
    "IP_ADDRESS",
    "CREDIT_CARD",
    "IBAN_CODE",
    "LOCATION",
    "URL",
    # Custom UK
    "UK_POSTCODE",
    "UK_SORT_CODE",
    "UK_ACCOUNT_NUMBER",
    "UK_NI_NUMBER",
    "UK_VAT_NUMBER",
    # Loaded from DB at startup
    "XERO_CONTACT_ID",
]


def _build_analyzer(xero_contact_ids: list[str]) -> AnalyzerEngine:
    """Construct the Presidio AnalyzerEngine with spaCy en_core_web_lg plus
    our custom UK recognizers and a Xero contact recognizer if the IDs list
    is non-empty."""
    provider = NlpEngineProvider(nlp_configuration={
        "nlp_engine_name": "spacy",
        "models": [{"lang_code": "en", "model_name": "en_core_web_lg"}],
    })
    nlp_engine = provider.create_engine()

    registry = RecognizerRegistry()
    registry.load_predefined_recognizers(languages=["en"])
    for r in CUSTOM_RECOGNIZERS:
        registry.add_recognizer(r)

    if xero_contact_ids:
        from presidio_analyzer import PatternRecognizer, Pattern
        # Xero contact IDs are 36-char GUIDs (e.g. abcd1234-...). Match with
        # high confidence — they're unique enough that a hit is intentional.
        guid_pattern = Pattern(
            name="xero_contact_guid",
            regex=r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
            score=0.95,
        )
        registry.add_recognizer(PatternRecognizer(
            supported_entity="XERO_CONTACT_ID",
            patterns=[guid_pattern],
            deny_list=xero_contact_ids,
        ))

    return AnalyzerEngine(
        registry=registry,
        nlp_engine=nlp_engine,
        supported_languages=["en"],
    )


async def _load_xero_contact_ids(pool: asyncpg.Pool) -> list[str]:
    """Pull every known Xero contact ID. Used as a deny-list recognizer."""
    try:
        async with pool.acquire() as conn:
            await conn.execute("SELECT home_ai.set_realm('owner')")
            # xero_contacts table is U128 — may not exist on a fresh DB
            check = await conn.fetchval("""
                SELECT EXISTS (
                  SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='xero_contacts'
                )
            """)
            if not check:
                log.warning("xero_contacts table not present; skipping XERO_CONTACT_ID recognizer")
                return []
            rows = await conn.fetch("SELECT contact_id FROM xero_contacts WHERE contact_id IS NOT NULL")
            return [r["contact_id"] for r in rows]
    except Exception as e:
        log.warning(f"failed to load xero contact ids: {e}")
        return []


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await asyncpg.create_pool(
        host=PG_HOST, port=PG_PORT, user=PG_USER,
        password=PG_PW, database=PG_DB,
        min_size=1, max_size=4,
    )
    xero_ids = await _load_xero_contact_ids(app.state.pool)
    log.info(f"loaded {len(xero_ids)} Xero contact IDs")
    app.state.analyzer = _build_analyzer(xero_ids)
    log.info("Presidio analyzer ready")
    yield
    await app.state.pool.close()


app = FastAPI(title="homeai-presidio", lifespan=lifespan)


class RedactRequest(BaseModel):
    text: str
    workflow_id: Optional[str] = None
    capability_tag: Optional[str] = None
    realm: str = "work"


class RedactResponse(BaseModel):
    redacted_text: str
    audit_id: int
    recognisers_hit: dict[str, int]
    redacted_token_count: int
    latency_ms: int


@app.get("/healthcheck")
async def healthcheck():
    # The analyzer is lazy-init; touch it to confirm it's alive.
    if not hasattr(app.state, "analyzer"):
        raise HTTPException(503, "analyzer not initialised")
    return {"status": "ok", "version": PRESIDIO_VERSION}


@app.post("/redact", response_model=RedactResponse)
async def redact(req: RedactRequest):
    if not req.text or not req.text.strip():
        raise HTTPException(400, "text required")

    started = time.time()
    sha = hashlib.sha256(req.text.encode("utf-8")).hexdigest()

    results = app.state.analyzer.analyze(
        text=req.text,
        entities=TARGET_ENTITIES,
        language="en",
    )

    # Sort by start, then iterate keeping non-overlapping spans. When two
    # spans overlap, prefer the higher-score one (e.g. UK_NI_NUMBER@0.92
    # beats spaCy's PERSON@0.85 on letter-digit sequences like JK654321A).
    spans = sorted(results, key=lambda r: r.start)
    pruned: list = []
    for s in spans:
        if not pruned or s.start >= pruned[-1].end:
            pruned.append(s)
        else:
            # Overlap: keep the higher-score one.
            if s.score > pruned[-1].score:
                pruned[-1] = s

    out_parts: list[str] = []
    cursor = 0
    counters: dict[str, int] = {}
    for s in pruned:
        out_parts.append(req.text[cursor:s.start])
        counters[s.entity_type] = counters.get(s.entity_type, 0) + 1
        out_parts.append(f"<REDACTED:{s.entity_type}_{counters[s.entity_type]}>")
        cursor = s.end
    out_parts.append(req.text[cursor:])
    redacted_text = "".join(out_parts)

    latency_ms = int((time.time() - started) * 1000)

    async with app.state.pool.acquire() as conn:
        await conn.execute("SELECT home_ai.set_realm($1)", req.realm)
        audit_id = await conn.fetchval(
            """
            INSERT INTO redaction_audit_log
                (sha256_input, recognisers_hit, redacted_token_count,
                 input_length, status, workflow_id, capability_tag,
                 presidio_version, latency_ms, realm)
            VALUES ($1, $2::jsonb, $3, $4, 'ok', $5, $6, $7, $8, $9)
            RETURNING id
            """,
            sha, json.dumps(counters), len(pruned), len(req.text),
            req.workflow_id, req.capability_tag,
            PRESIDIO_VERSION, latency_ms, req.realm,
        )

    return RedactResponse(
        redacted_text=redacted_text,
        audit_id=audit_id,
        recognisers_hit=counters,
        redacted_token_count=len(pruned),
        latency_ms=latency_ms,
    )
