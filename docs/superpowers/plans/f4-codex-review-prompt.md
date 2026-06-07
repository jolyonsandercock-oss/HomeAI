# Codex task — red-team the F4 plan v2 (Option C) BEFORE execution

## Your role
Senior security+infra reviewer. **Read-only.** Do NOT modify files, compose,
containers, or the DB. Find flaws; give a clear go/no-go.

## Context
Your v1 review correctly rejected the Tecnativa socket-proxy: `docker exec`
forces `CONTAINERS=1+POST=1`, which also permits `POST /containers/create`
(host-mount → root). The plan was revised to **Option C**: build-dashboard
stops using Docker entirely; model-evaluator (already a FastAPI service on
:8008, on ai-internal) exposes a narrow SSE endpoint that runs
`run_benchmark.py` **inside its own container**, and build-dashboard relays it
over HTTP.

## What to review
- Plan v2: `/home_ai/docs/superpowers/plans/2026-06-07-f4-docker-socket-proxy.md`
- `/home_ai/services/model-evaluator/main.py` (new SSE endpoint), `run_benchmark.py`
- `/home_ai/services/build-dashboard/main.py` (the `/api/benchmark/stream` relay ~L5988), `Dockerfile`
- `/home_ai/docker-compose.yml` (build-dashboard volume removal; model-evaluator)

## Red-team these specifically
1. **Isolation actually achieved:** after the change, does build-dashboard have
   ANY path to the Docker daemon left (socket mount, CLI, DOCKER_HOST, any other
   subprocess)? Grep to confirm zero.
2. **SSE relay correctness:** does `aiter_raw()` passthrough preserve event
   framing and stream incrementally (not buffer to completion)? Any timeout/
   backpressure/connection-leak issue with `timeout=None`? Will a client
   disconnect cleanly cancel the upstream benchmark?
3. **New exposure on model-evaluator:** the SSE endpoint runs an arbitrary-ish
   subprocess (`run_benchmark.py` with `model`/`tier` params). Are `model`/`tier`
   passed as argv (safe) or shell-interpolated (injection)? Is `model`
   validated/allow-listed, or can a caller pass arbitrary `--model` values that
   `run_benchmark.py` might misuse? Note: :8008 is host-published + unauth —
   does this endpoint let an unauth caller on the host trigger expensive runs or
   worse? Recommend a guard if so.
3b. **DoS / concurrency:** can repeated calls spawn unbounded benchmark
   subprocesses on model-evaluator? Should it be single-flight?
4. **Regression:** does removing the Docker CLI from build-dashboard's
   Dockerfile break anything else? Does anything else in build-dashboard import
   `asyncio.subprocess`/call the old handler?
5. **Rollback** completeness.

## Output
Verdict: **SAFE TO EXECUTE / EXECUTE WITH CHANGES / DON'T**, then numbered
required changes with file:line evidence. Prioritise the injection/exposure
questions in #3 — that's the new attack surface this introduces.
