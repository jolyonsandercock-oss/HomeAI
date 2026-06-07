# F4 — Remove build-dashboard's raw Docker socket access

**Goal:** build-dashboard (web-facing, behind Authelia) mounts `/var/run/docker.sock` **read-write** → effective **root on the host** if compromised. Remove that access entirely without breaking the one feature that needs it.

**Status:** PLAN v2 — revised after Codex review (2026-06-07). **Option A (socket-proxy) REJECTED** (see below). Primary approach is now **Option C**. Re-review v2 via `f4-codex-review-prompt.md` before execution.

---

## Verified current state

- Mount: `docker-compose.yml:303` → `- /var/run/docker.sock:/var/run/docker.sock` (RW).
- **Only** socket consumer: `GET /api/benchmark/stream` (`services/build-dashboard/main.py:5988`) runs
  `/usr/local/bin/docker exec … homeai-model-evaluator python -u /app/run_benchmark.py --model <m> --tier <t>` and relays stdout as SSE. (Container status is HTTP-probe based; hardware panel uses `nvidia-smi`. Confirmed by Codex — no other Docker/socket use.)
- Docker CLI present at `/usr/local/bin/docker` (`services/build-dashboard/Dockerfile:7`).
- **model-evaluator is already a FastAPI service** (`services/model-evaluator/Dockerfile:6` → uvicorn `main:app` on `:8008`), on `ai-internal`. It already has `run_benchmark.py` and `_benchmark()` locally. build-dashboard is also on `ai-internal` → can reach `homeai-model-evaluator:8008` over HTTP today.
- `:ro` is NOT mitigation (the socket is a command channel; mount mode isn't the authz boundary). Codex confirmed.

---

## Why Option A (Tecnativa socket-proxy) is rejected

`docker exec` needs `POST /containers/{id}/exec` + `POST /exec/{id}/start`. In Tecnativa v0.3.0 those require `CONTAINERS=1, EXEC=1, POST=1`. But the proxy gates by **path-prefix + method**, not per-operation — so `CONTAINERS=1 + POST=1` *also* permits `POST /containers/create` (with `-v /:/host` → host root), plus stop/kill/rename/prune. It **cannot** allow `exec` while denying `create`. So Option A does **not** remove the host-root vector — it only blocks the images/networks/volumes/swarm API sections. Not worth the moving part. (Codex, citing the v0.3.0 haproxy.cfg mapping.)

---

## Option C — model-evaluator owns the benchmark; dashboard gets ZERO Docker

build-dashboard stops shelling out to Docker and instead calls a narrow SSE endpoint on model-evaluator, which runs the benchmark **inside its own container** (where `run_benchmark.py` already lives). Real isolation: the web-facing container has no socket, no Docker CLI, no `DOCKER_HOST`.

### Task 1: add the benchmark SSE endpoint to model-evaluator
**File:** `services/model-evaluator/main.py`
- [ ] **Step 1:** Add (reuses the exact streaming logic build-dashboard had, minus the `docker exec` prefix — it runs locally now):
  ```python
  import os
  import asyncio.subprocess as asp
  from fastapi.responses import StreamingResponse

  @app.get("/api/benchmark/stream")
  async def benchmark_stream(model: str = "qwen2.5:7b", tier: str = "hot"):
      if tier not in ("hot", "medium", "heavy"):
          raise HTTPException(400, "tier must be hot|medium|heavy")
      cmd = ["python", "-u", "/app/run_benchmark.py", "--model", model, "--tier", tier]
      async def gen():
          proc = await asp.create_subprocess_exec(
              *cmd, stdout=asp.PIPE, stderr=asp.STDOUT,
              env={**os.environ, "PYTHONUNBUFFERED": "1"})
          try:
              while True:
                  line = await proc.stdout.readline()
                  if not line:
                      break
                  yield f"data: {line.decode('utf-8', 'replace').rstrip()}\n\n"
              await proc.wait()
              yield f"event: done\ndata: exit_code={proc.returncode}\n\n"
          finally:
              if proc.returncode is None:
                  proc.kill()
      return StreamingResponse(gen(), media_type="text/event-stream")
  ```
- [ ] **Step 2:** `docker compose build model-evaluator && docker compose up -d model-evaluator`. Smoke: `docker exec homeai-caddy wget -qO- 'http://homeai-model-evaluator:8008/api/benchmark/stream?model=qwen2.5:7b&tier=hot'` streams lines + `exit_code=0`.

### Task 2: build-dashboard relays over HTTP, loses Docker
**Files:** `services/build-dashboard/main.py` (the `/api/benchmark/stream` handler ~L5988), `services/build-dashboard/Dockerfile:7`, `docker-compose.yml` (build-dashboard service)
- [ ] **Step 3:** Replace the `docker exec` subprocess with an HTTP relay (raw passthrough preserves SSE framing):
  ```python
  @app.get("/api/benchmark/stream")
  async def benchmark_stream(model: str = Query("qwen2.5:7b"),
                             tier: str = Query("hot", pattern="^(hot|medium|heavy)$")):
      url = (f"http://homeai-model-evaluator:8008/api/benchmark/stream"
             f"?model={model}&tier={tier}")
      async def gen():
          async with httpx.AsyncClient(timeout=None) as client:
              async with client.stream("GET", url) as r:
                  async for chunk in r.aiter_raw():
                      yield chunk
      return StreamingResponse(gen(), media_type="text/event-stream")
  ```
  Remove the now-dead `asyncio.subprocess as asp` import if unused elsewhere.
- [ ] **Step 4:** `docker-compose.yml` build-dashboard: **remove** the `- /var/run/docker.sock:/var/run/docker.sock` volume. (No `DOCKER_HOST` is added — there is no Docker access at all.)
- [ ] **Step 5:** `Dockerfile:7` — remove the Docker CLI install line (no longer needed). Optional but recommended (smaller image, no CLI to abuse).
- [ ] **Step 6:** `docker compose build build-dashboard && docker compose up -d build-dashboard`.

### Task 3: verify isolation + no regression
- [ ] **Step 7 (feature works):** trigger a Deep benchmark from the dashboard → SSE streams, exits 0 (now sourced from model-evaluator).
- [ ] **Step 8 (isolation — the point):** `docker exec homeai-build-dashboard sh -c 'ls -la /var/run/docker.sock; which docker; echo $DOCKER_HOST'` → socket absent, no CLI, no DOCKER_HOST. The container literally cannot talk to Docker.
- [ ] **Step 9:** dashboard container-status + hardware panels still render (they never used the socket).

### Task 4: tighten the checker + commit
- [ ] **Step 10:** `scripts/audit-invariants.py` INV-DOCKER-SOCK: any `docker.sock` mount on an **app** service is FAIL **including `:ro`** (`:ro` is not mitigation). Only an explicit, documented gatekeeper may mount it. Refresh `.audit-baseline.txt`.
- [ ] **Step 11:** commit model-evaluator + build-dashboard + compose + Dockerfile + checker.

---

## Rollback
Revert the build-dashboard handler to the `docker exec` version and re-add the `docker.sock` volume + Dockerfile CLI line; `docker compose up -d build-dashboard`. model-evaluator's new endpoint is additive and harmless if left.

## Residual / notes
- model-evaluator `:8008` is host-published (`ports: ["8008:8008"]`, 0.0.0.0) and already serves unauthenticated internal endpoints (`/api/models`, deploy, etc.). The benchmark endpoint inherits that posture — it does **not** widen it (build-dashboard reaches it via internal DNS). Tightening 8008's host binding is a separate INV-PORTS item.
- Net effect: build-dashboard goes from host-root-capable to **zero** Docker access.

## Negative tests retained for the checker (defence-in-depth, even though C has no proxy)
If anyone ever reintroduces socket access, the checker must catch it; and these are the ops a socket would expose: `docker create -v /:/host …`, `stop`, `kill`, `rename`, `container prune`. None are reachable under Option C.
