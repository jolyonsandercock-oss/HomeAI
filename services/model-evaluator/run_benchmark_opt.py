#!/usr/bin/env python3
"""Optimised benchmark runner for thinking-capable Qwen models (qwen3.5:9b).

Differs from run_benchmark.py in four ways, each an independently-toggleable
optimisation lever:
  1. think:false           — disable the qwen3 reasoning trace (huge latency win)
  2. U7 optimised prompts   — the qwen_prompts.py templates (entity hints, enum guards)
  3. temp=0 + tuned top_k   — overrides the model's baked-in temperature=1
  4. num_ctx cap            — shrinks KV cache so the model fits GPU VRAM

Reuses the scorers and sample sets from the stock runner so scores are
directly comparable to run_benchmark.py.

Usage (inside container):
    docker exec homeai-model-evaluator python /app/run_benchmark_opt.py \
        --model qwen3.5:9b --think off --prompts u7 --num-ctx 8192
"""
from __future__ import annotations

import argparse
import asyncio
import os
import time

import httpx

import run_benchmark as base  # reuse scorers + JSON parse
from benchmark_tasks import (
    EMAIL_CLASSIFICATION_SAMPLES,
    JSON_FORMAT_PROMPTS,
    INVOICE_EXTRACTION_SAMPLES,
    REPORT_PARSING_SAMPLES,
    SPEED_PROMPTS,
    SUITE,
    DEPLOYMENT_THRESHOLD,
    COMPOSITE_ACCURACY_WEIGHT,
    COMPOSITE_SPEED_WEIGHT,
)
import qwen_prompts as qp

OLLAMA = os.environ.get("OLLAMA_URL", "http://homeai-ollama:11434")


async def call(client, model, prompt, *, system=None, think=False,
               enforce_json=True, num_ctx=0, top_k=20) -> dict:
    options = {"temperature": 0.0, "top_p": 0.7, "top_k": top_k}
    if num_ctx:
        options["num_ctx"] = num_ctx
    body = {"model": model, "prompt": prompt, "stream": False,
            "think": think, "options": options}
    if enforce_json:
        body["format"] = "json"
    if system:
        body["system"] = system
    r = await client.post(f"{OLLAMA}/api/generate", json=body, timeout=180.0)
    r.raise_for_status()
    d = r.json()
    ec = d.get("eval_count", 0) or 0
    ed = d.get("eval_duration", 0) or 0
    td = d.get("total_duration", 0) or 0
    return {
        "text": d.get("response", ""),
        "output_tokens": ec,
        "tps": (ec / (ed / 1e9)) if ed > 0 else 0.0,
        "latency_ms": int(td / 1e6) if td else 0,
    }


async def run(model: str, tier: str, think: bool, use_u7: bool, num_ctx: int):
    label = f"think={'on' if think else 'off'} prompts={'u7' if use_u7 else 'plain'} ctx={num_ctx or 'default'}"
    print(f"╭{'─'*70}╮")
    print(f"│  OPT Benchmark — {model:<16s} {label:<33s}│")
    print(f"╰{'─'*70}╯\n")

    async with httpx.AsyncClient() as client:
        # ── Email classification ──
        print("▸ Email classification (10 samples):")
        scores, tps_s, lat_s = [], [], []
        for s in EMAIL_CLASSIFICATION_SAMPLES:
            if use_u7:
                prompt = qp.EMAIL_PROMPT.format(f=s["from"], s=s["subject"], b=s["body"])
                system = qp.SYS_CLASSIFY
            else:
                prompt = base.EMAIL_PROMPT.format(f=s["from"], s=s["subject"], b=s["body"])
                system = base.JSON_PREAMBLE
            out = await call(client, model, prompt, system=system, think=think,
                             num_ctx=num_ctx, top_k=20)
            sc, why = base.score_email(out, s["expected"])
            scores.append(sc); tps_s.append(out["tps"]); lat_s.append(out["latency_ms"])
            mark = "✓" if sc == 1.0 else ("·" if sc > 0 else "✗")
            print(f"  {mark} {s['id']:<12s} score={sc:.2f} {out['tps']:6.1f} t/s {out['latency_ms']:5d}ms {out['output_tokens']:4d}tok {why}")
        email_score = sum(scores) / len(scores)
        print(f"  → accuracy {email_score*100:.1f}%  avg {sum(tps_s)/len(tps_s):.1f} t/s  avg {sum(lat_s)//len(lat_s)}ms\n")

        # ── JSON validity ──
        print("▸ JSON validity (10 prompts):")
        js = []
        for i, p in enumerate(JSON_FORMAT_PROMPTS):
            out = await call(client, model, p, system=qp.SYS_JSON_ONLY, think=think,
                             num_ctx=num_ctx, top_k=40)
            sc, _ = base.score_json_format(out)
            js.append(sc)
            print(f"  {'✓' if sc==1.0 else '✗'} prompt_{i+1:02d}  {out['tps']:6.1f} t/s {out['latency_ms']:5d}ms")
        json_score = sum(js) / len(js)
        print(f"  → JSON validity {json_score*100:.1f}%\n")

        # ── Invoice extraction ──
        print("▸ Invoice extraction (5 samples):")
        inv = []
        for s in INVOICE_EXTRACTION_SAMPLES:
            prompt = (qp.INVOICE_PROMPT if use_u7 else base.INVOICE_PROMPT).format(t=s["text"])
            system = qp.SYS_JSON_ONLY if use_u7 else base.JSON_PREAMBLE
            out = await call(client, model, prompt, system=system, think=think,
                             num_ctx=num_ctx, top_k=40)
            sc, why = base.score_invoice(out, s["expected"])
            inv.append(sc)
            mark = "✓" if sc >= 0.8 else ("·" if sc > 0 else "✗")
            print(f"  {mark} {s['id']:<8s} score={sc:.2f} {out['tps']:6.1f} t/s {out['latency_ms']:6d}ms {why}")
        inv_score = sum(inv) / len(inv)
        print(f"  → invoice extraction {inv_score*100:.1f}%\n")

        # ── Report parsing ──
        print("▸ Report parsing (3 samples):")
        rep = []
        for s in REPORT_PARSING_SAMPLES:
            prompt = (qp.REPORT_PROMPT if use_u7 else base.REPORT_PROMPT).format(t=s["text"])
            system = qp.SYS_JSON_ONLY if use_u7 else base.JSON_PREAMBLE
            out = await call(client, model, prompt, system=system, think=think,
                             num_ctx=num_ctx, top_k=40)
            sc, why = base.score_invoice(out, s["expected"])
            rep.append(sc)
            mark = "✓" if sc >= 0.8 else ("·" if sc > 0 else "✗")
            print(f"  {mark} {s['id']:<10s} score={sc:.2f} {out['tps']:6.1f} t/s {out['latency_ms']:6d}ms {why}")
        rep_score = sum(rep) / len(rep)
        print(f"  → report parsing {rep_score*100:.1f}%\n")

        # ── Speed ──
        print(f"▸ Speed (tier prompt: {tier}):")
        out = await call(client, model, SPEED_PROMPTS.get(tier, SPEED_PROMPTS["hot"]),
                         system=qp.SYS_JSON_ONLY, think=think, num_ctx=num_ctx)
        target = SUITE[tier]["speed_" + tier]["target_tps"]
        speed_pct = min(100.0, out["tps"] / target * 100)
        print(f"  {out['tps']:.1f} t/s  (target {target} → {speed_pct:.0f}%)  {out['latency_ms']}ms")

    accuracy = (email_score + json_score + inv_score + rep_score) / 4
    composite = COMPOSITE_ACCURACY_WEIGHT * accuracy + COMPOSITE_SPEED_WEIGHT * (speed_pct / 100)
    print(f"\n╭{'─'*70}╮\n│  COMPOSITE  [{label}]")
    print(f"╰{'─'*70}╯")
    print(f"  email          {email_score*100:5.1f}%")
    print(f"  json validity  {json_score*100:5.1f}%")
    print(f"  invoice        {inv_score*100:5.1f}%")
    print(f"  reports        {rep_score*100:5.1f}%")
    print(f"  speed          {speed_pct:5.1f}%  ({out['tps']:.1f} t/s vs target {target})")
    print(f"  ─────────────────────────────────────")
    print(f"  composite      {composite*100:5.1f}%   (deploy threshold +{DEPLOYMENT_THRESHOLD*100:.0f}%)")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="qwen3.5:9b")
    p.add_argument("--tier", default="hot", choices=["hot", "medium", "heavy"])
    p.add_argument("--think", default="off", choices=["on", "off"])
    p.add_argument("--prompts", default="u7", choices=["u7", "plain"])
    p.add_argument("--num-ctx", type=int, default=0)
    args = p.parse_args()
    asyncio.run(run(args.model, args.tier, args.think == "on",
                    args.prompts == "u7", args.num_ctx))
