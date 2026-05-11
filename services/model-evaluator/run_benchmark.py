#!/usr/bin/env python3
"""Standalone benchmark runner using the comprehensive suite in
benchmark_tasks.py. Prints a clean report; does NOT write to Postgres
(use the model-evaluator service's webhook for that).

Usage:
    docker exec homeai-model-evaluator python /app/run_benchmark.py [--model qwen2.5:7b] [--tier hot]

Or from outside the container:
    docker run --rm --network home_ai_ai-internal -v /home_ai/services/model-evaluator:/app python:3.11-slim \
        sh -c 'pip install httpx -q && python /app/run_benchmark.py'
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import time
from typing import Any

import httpx

from benchmark_tasks import (
    SUITE,
    EMAIL_CLASSIFICATION_SAMPLES,
    JSON_FORMAT_PROMPTS,
    INVOICE_EXTRACTION_SAMPLES,
    REPORT_PARSING_SAMPLES,
    SPEED_PROMPTS,
    DEPLOYMENT_THRESHOLD,
    COMPOSITE_ACCURACY_WEIGHT,
    COMPOSITE_SPEED_WEIGHT,
)

OLLAMA = os.environ.get("OLLAMA_URL", "http://homeai-ollama:11434")

EMAIL_CATS = {"invoice", "action-required", "report-attachment",
              "school-medical", "property", "pub", "fyi", "junk"}

EMAIL_PROMPT = """You classify emails for a UK pub/property/family business.
From: {f}
Subject: {s}
Body: {b}

Return ONLY a JSON object: {{"category": <one of: invoice|action-required|report-attachment|school-medical|property|pub|fyi|junk>, "entity_id": <1=Trading|2=Estates|3=Personal|4=Family>}}
"""

INVOICE_PROMPT = """Extract invoice fields from this text. Return ONLY JSON.
Schema: {{ "supplier_name": str, "invoice_number": str, "invoice_date": "YYYY-MM-DD", "gross_amount": number, "currency": str, "category": str }}

Text:
{t}
"""

REPORT_PROMPT = """Parse this report. Return ONLY JSON matching the implied schema.
Text:
{t}
"""

# ─── Helpers ────────────────────────────────────────────────────
def parse_json(text: str) -> dict | None:
    """Find the first JSON object in `text`, tolerating ```json fences."""
    if not text:
        return None
    text = text.strip()
    text = re.sub(r"^```[a-z]*\n?", "", text).rstrip("`").rstrip()
    # Greedy match the outermost {...}
    start = text.find("{")
    end   = text.rfind("}")
    if start < 0 or end < 0 or end <= start:
        return None
    try:
        return json.loads(text[start:end + 1])
    except Exception:
        return None

JSON_PREAMBLE = (
    "You output valid JSON only. No preamble. No markdown. No prose around it. "
    "Your entire response is one parseable JSON object that matches the schema asked for."
)

async def call_ollama(client: httpx.AsyncClient, model: str, prompt: str,
                      enforce_json: bool = False) -> dict:
    body = {"model": model, "prompt": prompt, "stream": False,
            "options": {"temperature": 0.1}}
    if enforce_json:
        body["format"] = "json"
        body["system"] = JSON_PREAMBLE
    t0 = time.time()
    r = await client.post(
        f"{OLLAMA}/api/generate",
        json=body,
        timeout=120.0,
    )
    r.raise_for_status()
    d = r.json()
    eval_count   = d.get("eval_count", 0) or 0
    eval_dur_ns  = d.get("eval_duration", 0) or 0
    total_dur_ns = d.get("total_duration", 0) or 0
    return {
        "text":          d.get("response", ""),
        "input_tokens":  d.get("prompt_eval_count", 0) or 0,
        "output_tokens": eval_count,
        "tps":           (eval_count / (eval_dur_ns / 1e9)) if eval_dur_ns > 0 else 0.0,
        "latency_ms":    int(total_dur_ns / 1e6) if total_dur_ns else int((time.time() - t0) * 1000),
    }

# ─── Scorers ────────────────────────────────────────────────────
def score_email(out: dict, expected: dict) -> tuple[float, str]:
    parsed = parse_json(out["text"])
    if not parsed:
        return 0.0, "no JSON"
    cat_ok = parsed.get("category") == expected["category"]
    raw_eid = parsed.get("entity_id")
    try:
        eid = int(raw_eid) if raw_eid is not None else None
    except (TypeError, ValueError):
        eid = None
    eid_ok = (eid == expected["entity_id"])
    if cat_ok and eid_ok:
        return 1.0, "exact"
    if cat_ok:
        return 0.5, f"cat ok, entity {raw_eid}≠{expected['entity_id']}"
    return 0.0, f"cat {parsed.get('category')}≠{expected['category']}"

def score_json_format(out: dict) -> tuple[float, str]:
    parsed = parse_json(out["text"])
    return (1.0 if parsed is not None else 0.0,
            "valid JSON" if parsed is not None else "invalid JSON")

def score_invoice(out: dict, expected: dict) -> tuple[float, str]:
    parsed = parse_json(out["text"])
    if not parsed:
        return 0.0, "no JSON"
    matches = 0
    total   = 0
    for k, v in expected.items():
        total += 1
        got = parsed.get(k)
        if isinstance(v, (int, float)) and isinstance(got, (int, float)):
            if abs(float(got) - float(v)) <= 0.05:  # tolerance for amounts
                matches += 1
        elif str(got).strip().lower() == str(v).strip().lower():
            matches += 1
    return matches / total, f"{matches}/{total} fields"

# ─── Run ────────────────────────────────────────────────────────
async def run(model: str, tier: str):
    print(f"╭{'─'*70}╮")
    print(f"│  Benchmark — {model:<20s} tier={tier:<8s}{' '*22}│")
    print(f"╰{'─'*70}╯\n")

    async with httpx.AsyncClient() as client:
        # ── Email classification ────
        print("▸ Email classification (10 samples):")
        scores = []
        tps_samples = []
        for s in EMAIL_CLASSIFICATION_SAMPLES:
            out = await call_ollama(client, model, EMAIL_PROMPT.format(f=s["from"], s=s["subject"], b=s["body"]))
            tps_samples.append(out["tps"])
            sc, why = score_email(out, s["expected"])
            scores.append(sc)
            mark = "✓" if sc == 1.0 else ("·" if sc > 0 else "✗")
            print(f"  {mark} {s['id']:<12s}  score={sc:.2f}  {out['tps']:6.1f} t/s  {out['latency_ms']:4d}ms  {why}")
        email_score = sum(scores) / len(scores)
        email_tps   = sum(tps_samples) / len(tps_samples)
        print(f"  → accuracy {email_score*100:.1f}%   avg {email_tps:.1f} t/s\n")

        # ── JSON validity ────
        print("▸ JSON validity (10 prompts):")
        json_scores = []
        for i, p in enumerate(JSON_FORMAT_PROMPTS):
            out = await call_ollama(client, model, p)
            sc, why = score_json_format(out)
            json_scores.append(sc)
            mark = "✓" if sc == 1.0 else "✗"
            print(f"  {mark} prompt_{i+1:02d}    score={sc:.0f}     {out['tps']:6.1f} t/s  {out['latency_ms']:4d}ms")
        json_score = sum(json_scores) / len(json_scores)
        print(f"  → JSON validity {json_score*100:.1f}%\n")

        # ── Invoice extraction (medium-tier task — runs anyway for comparison) ────
        print("▸ Invoice extraction (5 samples — usually medium tier):")
        inv_scores = []
        for s in INVOICE_EXTRACTION_SAMPLES:
            out = await call_ollama(client, model, INVOICE_PROMPT.format(t=s["text"]))
            sc, why = score_invoice(out, s["expected"])
            inv_scores.append(sc)
            mark = "✓" if sc >= 0.8 else ("·" if sc > 0 else "✗")
            print(f"  {mark} {s['id']:<8s}  score={sc:.2f}  {out['tps']:6.1f} t/s  {out['latency_ms']:5d}ms  {why}")
        inv_score = sum(inv_scores) / len(inv_scores)
        print(f"  → invoice extraction {inv_score*100:.1f}%\n")

        # ── Report parsing ────
        print("▸ Report parsing (3 samples):")
        rep_scores = []
        for s in REPORT_PARSING_SAMPLES:
            out = await call_ollama(client, model, REPORT_PROMPT.format(t=s["text"]))
            sc, why = score_invoice(out, s["expected"])  # same per-field scorer
            rep_scores.append(sc)
            mark = "✓" if sc >= 0.8 else ("·" if sc > 0 else "✗")
            print(f"  {mark} {s['id']:<10s}  score={sc:.2f}  {out['tps']:6.1f} t/s  {out['latency_ms']:5d}ms  {why}")
        rep_score = sum(rep_scores) / len(rep_scores)
        print(f"  → report parsing {rep_score*100:.1f}%\n")

        # ── Speed (tier-specific prompt) ────
        print(f"▸ Speed (tier prompt: {tier}):")
        out = await call_ollama(client, model, SPEED_PROMPTS.get(tier, SPEED_PROMPTS["hot"]))
        target = SUITE[tier]["speed_" + tier]["target_tps"]
        speed_pct = min(100.0, out["tps"] / target * 100)
        print(f"  {out['tps']:.1f} t/s  (target {target} t/s → {speed_pct:.0f}%)   {out['latency_ms']}ms")

    # ── Composite ────
    print(f"\n╭{'─'*70}╮")
    print(f"│  COMPOSITE                                                           │")
    print(f"╰{'─'*70}╯")
    accuracy = (email_score + json_score + inv_score + rep_score) / 4
    composite = (COMPOSITE_ACCURACY_WEIGHT * accuracy +
                 COMPOSITE_SPEED_WEIGHT * (speed_pct / 100))
    print(f"  email          {email_score*100:5.1f}%")
    print(f"  json validity  {json_score*100:5.1f}%")
    print(f"  invoice        {inv_score*100:5.1f}%")
    print(f"  reports        {rep_score*100:5.1f}%")
    print(f"  speed          {speed_pct:5.1f}%  ({out['tps']:.1f} t/s vs target {target})")
    print(f"  ─────────────────────────────────────")
    print(f"  composite      {composite*100:5.1f}%   (weights: {COMPOSITE_ACCURACY_WEIGHT*100:.0f}% accuracy + {COMPOSITE_SPEED_WEIGHT*100:.0f}% speed)")
    print(f"  deploy threshold for replacement:  +{DEPLOYMENT_THRESHOLD*100:.0f}% composite over current")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="qwen2.5:7b")
    p.add_argument("--tier",  default="hot", choices=["hot", "medium", "heavy"])
    p.add_argument("--format", default="off", choices=["off", "json"],
                   help="off = legacy plain prompts; json = pass format:json + JSON system preamble")
    args = p.parse_args()
    # Patch via module-level rebind — keeps run() signature stable
    if args.format == "json":
        import functools, sys as _sys
        _mod = _sys.modules[__name__]
        _mod.call_ollama = functools.partial(_mod.call_ollama, enforce_json=True)
    asyncio.run(run(args.model, args.tier))
