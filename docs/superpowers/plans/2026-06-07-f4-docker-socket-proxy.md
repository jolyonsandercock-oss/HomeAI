# F4 — Remove build-dashboard's raw Docker socket access

**Goal:** The build-dashboard container (web-facing, behind Authelia) currently mounts `/var/run/docker.sock` **read-write**. A web surface with the raw Docker socket = effective **root on the host** if compromised. Reduce that blast radius without breaking the one feature that needs Docker.

**Status:** PLAN ONLY — to be reviewed via Codex (see `f4-codex-review-prompt.md`) before execution.

---

## Verified current state (2026-06-07)

- Mount: `docker-compose.yml:303` → `- /var/run/docker.sock:/var/run/docker.sock` (read-write).
- **Only** socket consumer in build-dashboard: `GET /api/benchmark/stream` (`services/build-dashboard/main.py:5993`) runs:
  ```
  /usr/local/bin/docker exec -e PYTHONUNBUFFERED=1 homeai-model-evaluator \
      python -u /app/run_benchmark.py --model <model> --tier <tier>
  ```
  i.e. a single `docker exec` into **one fixed container** (`homeai-model-evaluator`), streamed back as SSE.
- Container **status** on the dashboard is already socket-less (HTTP probes — `main.py:296`); the hardware panel uses `nvidia-smi`/host reads, not Docker.
- build-dashboard: container `homeai-build-dashboard`, listens **:8090**, networks `[ai-internal, ai-monitoring, ai-egress]`.

**Why `:ro` is NOT the fix:** a read-only *bind mount* only marks the socket file read-only; the Docker Engine API still accepts write/exec calls through it. `:ro` would pass a naive check while leaving full control intact. (Action item: tighten the checker so `:ro` on docker.sock no longer counts as resolved.)

---

## Options (security best → cheapest)

**Option C — HTTP benchmark endpoint (best; dashboard loses Docker entirely).**
model-evaluator exposes its own SSE endpoint that runs `run_benchmark.py`; build-dashboard calls it over HTTP like every other service. build-dashboard has **zero** Docker access. *Cost:* requires model-evaluator to be (or become) an HTTP service + rewrite the stream client. Bigger change; verify model-evaluator's runtime first.

**Option A — Docker socket proxy (recommended: proper + low-risk + compose-only).**
Put `tecnativa/docker-socket-proxy` in front of the engine, exposing **only** the API surface `docker exec` needs; build-dashboard talks to the proxy over the internal network and never touches the raw socket. Removes the host-root vectors (container create with host mounts, delete, image pull, etc.). *Residual:* the proxy filters by API *type*, not by target container — so `exec` into *any* container is still possible (not just model-evaluator). Acceptable given everything is behind Authelia; Option C closes even that.

**Option B — bespoke exec sidecar.** A tiny service that only runs the model-evaluator benchmark. Between A and C on effort/security. Not recommended over C.

**Recommendation: Option A now** (big risk reduction, contained, reversible), with Option C as a follow-up if we want to remove exec-into-any. The rest of this plan implements **A**.

---

## Implementation (Option A)

### Task 1: add the socket proxy

- [ ] **Step 1:** Add to `docker-compose.yml` (on `ai-monitoring`, shared with build-dashboard):
  ```yaml
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:0.3.0
    container_name: homeai-docker-proxy
    environment:
      CONTAINERS: "1"   # GET/inspect containers (resolve name->id for exec)
      EXEC: "1"         # /exec endpoints (docker exec)
      POST: "1"         # tecnativa blocks POST unless enabled; exec needs POST
      # everything else stays default-DENY:
      IMAGES: "0"
      NETWORKS: "0"
      VOLUMES: "0"
      INFO: "0"
      SERVICES: "0"
      TASKS: "0"
      SWARM: "0"
      SYSTEM: "0"
      AUTH: "0"
      BUILD: "0"
      COMMIT: "0"
      CONFIGS: "0"
      DISTRIBUTION: "0"
      NODES: "0"
      PLUGINS: "0"
      SECRETS: "0"
      SESSION: "0"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro   # proxy may read-only mount; it gatekeeps the API
    networks: [ai-monitoring]
    read_only: true
    restart: unless-stopped
  ```

- [ ] **Step 2:** Point build-dashboard at the proxy and drop the raw socket. In the `build-dashboard` service:
  - remove the volume line `- /var/run/docker.sock:/var/run/docker.sock`
  - add env `DOCKER_HOST: "tcp://homeai-docker-proxy:2375"`
  - confirm it shares the `ai-monitoring` network with the proxy (it does).

- [ ] **Step 3:** Deploy: `docker compose up -d docker-socket-proxy build-dashboard`.

### Task 2: verify the benchmark still works AND destructive ops are blocked

- [ ] **Step 4 (positive):** trigger a Deep benchmark from the dashboard (or `curl` `/api/benchmark/stream?model=qwen2.5:7b&tier=hot` with auth) → SSE lines stream and it exits 0. This proves `docker exec` works through the proxy.
- [ ] **Step 5 (negative — the whole point):** from inside build-dashboard, confirm dangerous ops are denied:
  ```
  docker exec homeai-build-dashboard sh -c 'docker -H tcp://homeai-docker-proxy:2375 ps'      # OK
  docker exec homeai-build-dashboard sh -c 'docker -H tcp://homeai-docker-proxy:2375 images'  # DENIED (403)
  docker exec homeai-build-dashboard sh -c 'docker -H tcp://homeai-docker-proxy:2375 run --rm -v /:/host alpine true'  # DENIED
  ```
  Expect 403/forbidden on images/run/volume — that's the blast-radius reduction.
- [ ] **Step 6:** confirm the dashboard's container-status + hardware panels still render (they don't use the socket, so should be unaffected).

### Task 3: tighten the checker + commit

- [ ] **Step 7:** Update `scripts/audit-invariants.py` INV-DOCKER-SOCK: a raw `docker.sock` mount on an app service is a FAIL **even with `:ro`** (`:ro` is not real mitigation); a socket mounted only on `homeai-docker-proxy` is allowed. Refresh `.audit-baseline.txt`.
- [ ] **Step 8:** Commit compose + checker.

---

## Rollback

Single step: restore build-dashboard's `- /var/run/docker.sock:/var/run/docker.sock` volume, remove `DOCKER_HOST`, `docker compose up -d build-dashboard`. The proxy container can stay or be removed; it touches nothing else.

## Open questions for review
1. Is `exec`-into-any-container (Option A residual) acceptable, or do we want Option C (no Docker at all on the dashboard)?
2. Does `docker exec` over the tecnativa proxy need any flag beyond `CONTAINERS`+`EXEC`+`POST` (e.g. `ALLOW_START`, version/ping)? Verify against tecnativa 0.3.0 docs.
3. Does build-dashboard's image actually contain the `docker` CLI client (it calls `/usr/local/bin/docker`)? Confirm it does and that the CLI honours `DOCKER_HOST` for `exec` streaming.
