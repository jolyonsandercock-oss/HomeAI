# U226 — GPU runtime hardening (CDI + driver watchdog + ollama observability)

**Realm:** work (ops/infra hardening; ops hardening is WORK-only per realm split).

**Trigger:** 2026-05-26 selftest. `homeai-ollama` exited 127 with OCI error `failed to fulfil mount request: open /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.595.58.03: no such file or directory`. Host driver upgraded 595.58.03 → 595.71.05 while container was running; bind-mount spec is frozen at create time. `restart: unless-stopped` doesn't fire because the failure is at OCI runc setup (pre-start), so the container can never self-heal.

**Status:** in progress.

---

## T1 — Immediate: recreate ollama against current driver

- [ ] `docker compose up -d --force-recreate ollama`
- [ ] curl http://127.0.0.1:11434/api/version → expect 200
- [ ] `docker exec homeai-ollama nvidia-smi --query-gpu=driver_version --format=csv,noheader` matches host

## T2 — Switch GPU services to CDI (Container Device Interface)

Legacy `deploy.resources.reservations.devices` freezes driver lib paths at create time. CDI resolves them at runtime via a regeneratable spec, so driver upgrades become transparent. nvidia-container-toolkit 1.19 already installed → supported.

- [ ] `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`
- [ ] Switch `ollama` service in `/home_ai/docker-compose.yml`: replace `deploy.resources.reservations.devices` with `devices: ["nvidia.com/gpu=all"]`
- [ ] Same for `build-dashboard` (also GPU-attached for cv tasks)
- [ ] `--force-recreate` both, verify

## T3 — Healthcheck on ollama container

Currently `HealthCheck: <nil>`. Add to compose:

```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -fs http://localhost:11434/api/version || exit 1"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 30s
```

## T4 — GPU driver-mismatch watchdog

systemd-path unit watching `/proc/driver/nvidia/version`. On change:

1. Regenerate `/etc/cdi/nvidia.yaml` via `nvidia-ctk cdi generate`
2. `docker compose -f /home_ai/docker-compose.yml up -d --force-recreate ollama build-dashboard`
3. Verify both `/api/version` and `/api/healthz` return 200
4. Telegram alert (info or error depending on outcome)

Files:
- `/etc/systemd/system/nvidia-driver-watch.path`
- `/etc/systemd/system/nvidia-driver-watch.service`
- `/home_ai/scripts/u226-gpu-driver-recover.sh`

Belt-and-braces: even with CDI, recreation forces the new spec to be picked up immediately rather than at next manual restart.

## T5 — Prometheus + alertmanager wiring

- [ ] Add blackbox-exporter probe for `http://homeai-ollama:11434/api/version`
- [ ] Alert rule `OllamaDown` (5m), routes to telegram via existing alertmanager → alert-sink-v1 path

## T6 — selftest.sh false-PASS bug

Section 1 reports `homeai-build-dashboard exited` as `[PASS]`. The `check` helper treats any non-empty `docker inspect` output as success. Must require state == `running`.

## T7 — Verify

- [ ] Run `/home_ai/scripts/selftest.sh` → 0 FAIL except `vault unsealed` (deferred to U221)
- [ ] Simulate driver mismatch by faking `nvidia-smi` output in container or by manually re-`docker stop && docker start` — confirm `restart: unless-stopped` is no longer the only recovery
- [ ] Confirm CDI: `docker exec homeai-ollama ls /usr/lib/x86_64-linux-gnu/libEGL_nvidia*` shows current driver only

---

## Deferred / out of scope

- **Vault auto-unseal** (U221) — covered separately. Once unsealed manually next time Jo is on-site with keys, file as P1 follow-up.
- **build-dashboard exit 127** — same NVIDIA root cause (also GPU-attached). Fixed transitively by T1+T2.
- Multi-GPU CDI mapping (single 3060 only; `nvidia.com/gpu=all` is sufficient).
