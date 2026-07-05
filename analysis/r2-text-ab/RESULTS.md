# R2 text-model A/B — invoice LINE extraction — Results

gemma4-doc:latest (incumbent, think:false) vs qwen2.5:72b-instruct-q4_0 (candidate), n=50 sampled invoices (seed=0.42). Prompt/schema/cross-foot gate copied verbatim from scripts/invoice-line-extract.py — this is an A/B of MODELS only.

| engine | n run | accepted | accept% | parse-fail | errors | median s | p90 s |
|---|---|---|---|---|---|---|---|
| gemma4-doc:latest | 50 | 13 | 26% | 0 | 0 | 7.4s | 50.4s |
| qwen2.5:72b-instruct-q4_0 | 50 | 13 | 26% | 0 | 0 | 20.5s | 129.0s |

## Extrapolated nightly 50-doc sweep at qwen2.5:72b speed

- at median (20.5s/doc): 17.1 min (0.28 h)
- at p90 (129.0s/doc, conservative): 107.5 min (1.79 h)

_Generated 2026-07-05 15:25:58_
