#!/usr/bin/env python3
"""qwen2.5:7b optimisation sweep — vary quant/format/sampling/system-prompt
and report which configuration wins on the comprehensive task suite.

Each config runs the SAME 4 task categories from benchmark_tasks.py
(email classification, JSON validity, invoice extraction, report parsing)
plus the hot-tier speed prompt. Composite weights match the production
scorer in run_benchmark.py.

Output: markdown table to stdout + raw JSON to /tmp/qwen_sweep.json
"""
from __future__ import annotations
import argparse
import asyncio
import json
import os
import re
import time
from dataclasses import dataclass, field, asdict
from typing import Any

import httpx

from benchmark_tasks import (
    EMAIL_CLASSIFICATION_SAMPLES, JSON_FORMAT_PROMPTS,
    INVOICE_EXTRACTION_SAMPLES, REPORT_PARSING_SAMPLES, SPEED_PROMPTS,
)

OLLAMA = os.environ.get("OLLAMA_URL", "http://homeai-ollama:11434")

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

JSON_PREAMBLE = (
    "You output valid JSON only. No preamble. No markdown. No prose around it. "
    "Your entire response is one parseable JSON object that matches the schema asked for."
)

EXTRACTION_PREAMBLE = (
    "You are a precise structured-data extractor. Output ONLY valid JSON matching the requested schema. "
    "Use null when a field is genuinely absent. Never invent values. "
    "Dates are ISO-8601 (YYYY-MM-DD). Numbers are bare numerics, no currency symbols."
)


@dataclass
class Config:
    """One configuration variant to test."""
    name: str
    model: str = "qwen2.5:7b"
    temperature: float = 0.1
    top_p: float | None = None
    top_k: int | None = None
    repeat_penalty: float | None = None
    num_predict: int | None = None
    num_ctx: int | None = None
    format_json: bool = False
    system_prompt: str | None = None  # extra system message
    extraction_system: bool = False   # use EXTRACTION_PREAMBLE for invoice/report


@dataclass
class Result:
    config: str
    email_acc: float = 0.0
    json_valid: float = 0.0
    invoice_acc: float = 0.0
    report_acc: float = 0.0
    speed_tps: float = 0.0
    avg_latency_ms: int = 0
    composite: float = 0.0
    samples_total: int = 0
    failures: int = 0
    elapsed_s: float = 0.0


def parse_json(text: str) -> dict | None:
    if not text:
        return None
    text = text.strip()
    text = re.sub(r"^```[a-z]*\n?", "", text).rstrip("`").rstrip()
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < 0 or end <= start:
        return None
    try:
        return json.loads(text[start:end + 1])
    except Exception:
        return None


async def call_ollama(client: httpx.AsyncClient, cfg: Config, prompt: str, *,
                      use_extraction_system: bool = False) -> dict:
    options: dict[str, Any] = {"temperature": cfg.temperature}
    if cfg.top_p is not None:        options["top_p"] = cfg.top_p
    if cfg.top_k is not None:        options["top_k"] = cfg.top_k
    if cfg.repeat_penalty is not None: options["repeat_penalty"] = cfg.repeat_penalty
    if cfg.num_predict is not None:  options["num_predict"] = cfg.num_predict
    if cfg.num_ctx is not None:      options["num_ctx"] = cfg.num_ctx

    body = {"model": cfg.model, "prompt": prompt, "stream": False, "options": options}

    if cfg.format_json:
        body["format"] = "json"
        if use_extraction_system and cfg.extraction_system:
            body["system"] = EXTRACTION_PREAMBLE
        else:
            body["system"] = JSON_PREAMBLE
    elif cfg.system_prompt:
        body["system"] = cfg.system_prompt

    t0 = time.time()
    r = await client.post(f"{OLLAMA}/api/generate", json=body, timeout=180.0)
    r.raise_for_status()
    d = r.json()
    eval_count = d.get("eval_count", 0) or 0
    eval_dur = d.get("eval_duration", 0) or 0
    total_dur = d.get("total_duration", 0) or 0
    return {
        "text": d.get("response", ""),
        "tps": (eval_count / (eval_dur / 1e9)) if eval_dur > 0 else 0.0,
        "latency_ms": int(total_dur / 1e6) if total_dur else int((time.time() - t0) * 1000),
    }


def score_email(out: dict, expected: dict) -> float:
    parsed = parse_json(out["text"])
    if not parsed:
        return 0.0
    cat_ok = parsed.get("category") == expected["category"]
    raw_eid = parsed.get("entity_id")
    try:
        eid = int(raw_eid) if raw_eid is not None else None
    except (TypeError, ValueError):
        eid = None
    eid_ok = (eid == expected["entity_id"])
    if cat_ok and eid_ok:
        return 1.0
    if cat_ok:
        return 0.5
    return 0.0


def score_invoice(out: dict, expected: dict) -> float:
    parsed = parse_json(out["text"])
    if not parsed:
        return 0.0
    matches = total = 0
    for k, v in expected.items():
        total += 1
        got = parsed.get(k)
        if isinstance(v, (int, float)) and isinstance(got, (int, float)):
            if abs(float(got) - float(v)) <= 0.05:
                matches += 1
        elif str(got).strip().lower() == str(v).strip().lower():
            matches += 1
    return matches / total if total else 0.0


async def run_config(cfg: Config) -> Result:
    print(f"\n▸ {cfg.name}")
    t0 = time.time()
    res = Result(config=cfg.name)
    failures = 0
    latencies: list[int] = []
    speeds: list[float] = []

    async with httpx.AsyncClient() as client:
        # Email
        scores = []
        for s in EMAIL_CLASSIFICATION_SAMPLES:
            try:
                out = await call_ollama(client, cfg, EMAIL_PROMPT.format(f=s["from"], s=s["subject"], b=s["body"]))
                scores.append(score_email(out, s["expected"]))
                latencies.append(out["latency_ms"])
                speeds.append(out["tps"])
            except Exception:
                failures += 1
                scores.append(0.0)
        res.email_acc = sum(scores) / max(len(scores), 1)
        print(f"  email      {res.email_acc*100:5.1f}%  ({sum(scores):.1f}/{len(scores)})")

        # JSON validity
        jscores = []
        for p in JSON_FORMAT_PROMPTS:
            try:
                out = await call_ollama(client, cfg, p)
                jscores.append(1.0 if parse_json(out["text"]) is not None else 0.0)
                latencies.append(out["latency_ms"])
                speeds.append(out["tps"])
            except Exception:
                failures += 1
                jscores.append(0.0)
        res.json_valid = sum(jscores) / max(len(jscores), 1)
        print(f"  json       {res.json_valid*100:5.1f}%")

        # Invoice extraction (use extraction system if cfg requests)
        iscores = []
        for s in INVOICE_EXTRACTION_SAMPLES:
            try:
                out = await call_ollama(client, cfg, INVOICE_PROMPT.format(t=s["text"]),
                                        use_extraction_system=True)
                iscores.append(score_invoice(out, s["expected"]))
                latencies.append(out["latency_ms"])
                speeds.append(out["tps"])
            except Exception:
                failures += 1
                iscores.append(0.0)
        res.invoice_acc = sum(iscores) / max(len(iscores), 1)
        print(f"  invoice    {res.invoice_acc*100:5.1f}%")

        # Report parsing
        rscores = []
        for s in REPORT_PARSING_SAMPLES:
            try:
                out = await call_ollama(client, cfg, REPORT_PROMPT.format(t=s["text"]),
                                        use_extraction_system=True)
                rscores.append(score_invoice(out, s["expected"]))  # same field-match scorer
                latencies.append(out["latency_ms"])
                speeds.append(out["tps"])
            except Exception:
                failures += 1
                rscores.append(0.0)
        res.report_acc = sum(rscores) / max(len(rscores), 1)
        print(f"  reports    {res.report_acc*100:5.1f}%")

        # Hot-tier speed prompt
        try:
            out = await call_ollama(client, cfg, SPEED_PROMPTS["hot"])
            res.speed_tps = out["tps"]
            latencies.append(out["latency_ms"])
            speeds.append(out["tps"])
        except Exception:
            failures += 1

    res.failures = failures
    res.samples_total = len(latencies)
    res.avg_latency_ms = int(sum(latencies) / len(latencies)) if latencies else 0
    res.elapsed_s = time.time() - t0

    accuracy = (res.email_acc + res.json_valid + res.invoice_acc + res.report_acc) / 4
    target_tps = 60.0  # hot tier target
    speed_pct = min(1.0, res.speed_tps / target_tps)
    res.composite = round(100 * (0.7 * accuracy + 0.3 * speed_pct), 1)
    print(f"  ⇒ composite {res.composite}%  speed {res.speed_tps:.1f} t/s  latency {res.avg_latency_ms}ms")
    return res


CONFIGS: list[Config] = [
    # 1. Current baseline (matches existing /webhook/model-evaluator-manual)
    Config(name="A_baseline",     temperature=0.1, format_json=False),

    # 2. format:json — proven JSON booster from sprint U5
    Config(name="B_format_json",  temperature=0.1, format_json=True),

    # 3. Deterministic
    Config(name="C_temp_0",       temperature=0.0, format_json=True),

    # 4. Tighter sampling
    Config(name="D_topp_0.7",     temperature=0.1, top_p=0.7, top_k=40, format_json=True),

    # 5. Output cap (speed/cost test)
    Config(name="E_npredict_256", temperature=0.0, num_predict=256, format_json=True),

    # 6. Extraction-tuned system prompt for invoice/report
    Config(name="F_extract_sys",  temperature=0.0, format_json=True, extraction_system=True),

    # 7. Combined winner-candidate (deterministic + tight + cap + extraction system)
    Config(name="G_combined",     temperature=0.0, top_p=0.7, top_k=40, num_predict=384,
                                  format_json=True, extraction_system=True),
]


async def main(args):
    print(f"╭{'─'*66}╮")
    print(f"│  qwen2.5:7b optimisation sweep — {len(CONFIGS)} configs              │")
    print(f"╰{'─'*66}╯")

    results: list[Result] = []
    for cfg in CONFIGS:
        if args.only and cfg.name not in args.only.split(","):
            continue
        results.append(await run_config(cfg))

    print(f"\n╭{'─'*78}╮")
    print(f"│  COMPARISON                                                                  │")
    print(f"╰{'─'*78}╯")
    header = f"{'config':<18s}{'email':>7s}{'json':>7s}{'invoice':>9s}{'reports':>9s}{'speed':>8s}{'composite':>11s}"
    print(header)
    print('─' * len(header))
    for r in sorted(results, key=lambda x: x.composite, reverse=True):
        print(f"{r.config:<18s}"
              f"{r.email_acc*100:6.1f}%{r.json_valid*100:6.1f}%"
              f"{r.invoice_acc*100:8.1f}%{r.report_acc*100:8.1f}%"
              f"{r.speed_tps:7.1f}t"
              f"{r.composite:10.1f}%")

    if results:
        winner = max(results, key=lambda x: x.composite)
        print(f"\n  → winner: {winner.config}  (composite {winner.composite}%)")

        out_path = "/tmp/qwen_sweep.json"
        with open(out_path, "w") as f:
            json.dump([asdict(r) for r in results], f, indent=2)
        print(f"  → raw results saved to {out_path}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--only", help="comma-separated subset of config names to run")
    args = p.parse_args()
    asyncio.run(main(args))
