# Codex task — red-team the F4 docker-socket-proxy plan BEFORE execution

## Your role
Senior security+infra reviewer. **Read-only.** Do NOT modify files, compose,
containers, or the database. Review the plan and the facts it rests on, find
flaws, and say clearly whether it's safe to execute as written.

## What to review
- The plan: `/home_ai/docs/superpowers/plans/2026-06-07-f4-docker-socket-proxy.md`
- The code it changes: `/home_ai/services/build-dashboard/main.py` (esp. the
  `/api/benchmark/stream` handler ~L5990 and any other Docker/socket use),
  and `/home_ai/docker-compose.yml` (the `build-dashboard` service + the
  `docker.sock` mount).

## Context (verify, don't trust)
build-dashboard is a web-facing dashboard (behind Authelia) that currently
mounts `/var/run/docker.sock` **read-write**. The plan replaces that with a
`tecnativa/docker-socket-proxy` exposing only `CONTAINERS`+`EXEC`+`POST`, sets
`DOCKER_HOST=tcp://homeai-docker-proxy:2375` on build-dashboard, and removes the
raw mount. The dashboard's only Docker use is one `docker exec` into
`homeai-model-evaluator` to stream a benchmark.

## Specifically red-team these (the plan may be wrong)
1. **Completeness of socket usage:** is `/api/benchmark/stream` really the ONLY
   thing in build-dashboard that touches the Docker socket/CLI? Grep for every
   `docker`, `.sock`, `subprocess`, `DOCKER_HOST`, `containers`, `/exec`. If
   anything else uses it, the plan breaks that feature — list it.
2. **Proxy permission minimality + sufficiency:** with tecnativa 0.3.0, do
   `CONTAINERS=1, EXEC=1, POST=1` (everything else 0) **exactly** cover
   `docker exec <name> <cmd>` (name→id resolve, exec create, exec start,
   stream) and NOTHING more? Is any of these three actually unnecessary? Is
   anything missing (ping/version/start)? Cite the tecnativa endpoint mapping.
3. **Residual risk:** the proxy can't restrict exec to a single container, so
   build-dashboard could `exec` into ANY container. Is that an acceptable
   residual behind Authelia, or should this be Option C (model-evaluator
   exposes an HTTP endpoint; dashboard gets NO Docker access)? Give a
   recommendation with reasoning.
4. **`:ro` claim:** confirm the plan's assertion that a read-only bind mount of
   docker.sock does NOT prevent Engine API writes (i.e. `:ro` is not real
   mitigation). State whether that's correct.
5. **Breakage / mechanics:** does build-dashboard's image actually contain the
   `docker` CLI at `/usr/local/bin/docker`, and will that CLI honour
   `DOCKER_HOST=tcp://...` for an `exec` with a streamed stdout? Any TLS
   expectation that a plain-HTTP `:2375` proxy would violate?
6. **Network:** build-dashboard is on `[ai-internal, ai-monitoring, ai-egress]`;
   the plan puts the proxy on `ai-monitoring`. Confirm they can reach each other
   and that the proxy is NOT exposed on a host port.
7. **Rollback:** is the one-step rollback genuinely complete and safe?

## Output
A short verdict: **SAFE TO EXECUTE / EXECUTE WITH CHANGES / DON'T**, then a
numbered list of any required changes (with file:line evidence), then the
Option A vs Option C recommendation. Prioritise correctness over politeness —
if the proxy flags are wrong or a socket consumer was missed, say so plainly.
