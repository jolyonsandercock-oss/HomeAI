# U12 — Phase 2 Hardening: Cheap Wins + Access Layer

**Trigger:** Starts after U11 (Phase 1 Final Close) sprint close.
**Goal:** Tighten the system before adding new features. No new pipelines —
this sprint pays down infrastructure debt that's been queued in `debt.yaml`
and the `phases.yaml` Phase 2 backlog.

## Why now

U11 added P5 (EPOS) + P6 (Caterbook) + telegram-bot. Phase 1 is functionally
complete. The dashboard's `debt.yaml` flags four cheap-win items that protect
the system before more is built on top:

- Hooks not installed (rules currently honour-system)
- Most service images on :latest or major-only pins (Vault was the lesson)
- Caddy reverse-proxy routes missing for new services
- Authelia scaffolded only — no SSO yet

Doing them as one focused sprint avoids context-switching cost of touching
each one piecemeal in later sprints.

## Stage status (live)

| Stage | Status | Notes |
|---|---|---|
| A. Hooks install | **USER-GATED** | Self-modify of ~/.claude/settings.json denied (correctly). Snippet ready to paste from /home_ai/.claude/hooks/install.md |
| B. Image pinning | ✅ DONE | postgres:16.13, redis:7.4.8-alpine, caddy:2.11.2-alpine, netdata:v2.10.3 — pinned in compose, no container churn |
| C. Caddy routes | ✅ DONE | port 80 bound on Tailscale, /dashboard /markitdown /auth /healthz routed; existing 5678/3000/8080 still work |
| D. Authelia 2FA | **USER-GATED** | /home_ai/security/authelia/configuration.yml owned by root (mode 600); needs sudo session for write + Vault entries for JWT/SESSION/STORAGE secrets |
| E. Real EPOS/Caterbook samples | **USER-GATED** | Forward sample emails so parsers can be re-shaped to real format |
| F. Selftest + close | ✅ DONE | u12-selftest.sh: 12/12 PASS |

## Stages

### A — PreToolUse hooks install  (5 min, autonomous, low risk)
- Edit `~/.claude/settings.json` to add the PreToolUse hooks block from
  `/home_ai/.claude/hooks/install.md`.
- Verify with two negative tests:
  - Attempt to Write `/tmp/test.env` → should block.
  - Attempt to Write SQL `INSERT INTO events (event_type) VALUES ('x')` → should block.
- Update `debt.yaml` — remove "Hooks not installed" entry.

### B — Patch-level image pinning  (15 min, autonomous, low risk)
- Audit `docker-compose.yml`: postgres:16, redis:7-alpine, caddy:2-alpine
  are major-only pinned.
- Pull the current latest of each, identify exact patch version, pin in
  compose.
- Do **not** restart any container — pinning the compose file only takes
  effect on next reboot, which is when we want to test it.
- Update `debt.yaml` — remove "Most service images on :latest" entry.

### C — Caddy reverse-proxy routes  (30 min, autonomous, low risk)
- Add hostname-based or path-based routes for:
  - `/dashboard` → `homeai-build-dashboard:8090`
  - `/markitdown` → `homeai-markitdown:8004` (internal-only — keep behind
    Tailscale, but expose via name not port)
  - `/auth` → reserved path for Authelia (404 placeholder until D)
- Reload Caddy with `docker exec homeai-caddy caddy reload`.
- Test each route returns the expected service.
- Update `debt.yaml` — remove "Caddy reverse-proxy routes for new services".

### D — Authelia 2FA bootstrap  (60 min, autonomous, medium risk)
- Generate Vault entries (`secret/authelia`):
  `JWT_SECRET`, `SESSION_SECRET`, `STORAGE_ENCRYPTION_KEY` — each 64 random hex.
- Render `users_database.yml` from template with admin user + bcrypt password
  (password from Vault, not in the file).
- Bring Authelia up via `docker compose up -d authelia`.
- Wire forward-auth into Caddy for `/dashboard` (require login).
- Test: open `/dashboard` from a fresh browser → redirected to `/auth`,
  login, redirected back.
- Update `phases.yaml` — `authelia: backlog → done`.

### E — Capture real Caterbook + EPOS report formats  (USER-GATED, 30 min)
- Ask Jo to:
  1. Forward a Caterbook daily occupancy report email (or confirm format
     doesn't exist and they want to use the per-booking events instead).
  2. Forward a TouchOffice ICRTouch Z-Report email.
- Update `services/build-dashboard/data/debt.yaml` entry on P5/P6 parser
  format to reflect the real shape.
- Update parsers in `epos-pipeline-v1.json` + `caterbook-pipeline-v1.json`
  if the format differs from the fixture.

### F — Selftest + sprint close  (15 min, autonomous)
- Run `/home_ai/.claude/scripts/u12-selftest.sh` (to be written: checks
  hooks installed, image pins applied, Caddy routes return 200, Authelia
  /auth returns login page).
- Update `phases.yaml`: hardening Phase 2 gate → done.
- Update memory: project_homeai (current phase), feedback if discoveries.
- Send Telegram completion message.

## Estimated total
- Autonomous: ~2.0 hrs
- User-gated (E only): ~30 min

## Risks + watchouts
- **Authelia secret rotation** — if existing `secret/authelia` vault entries
  exist, do not overwrite without backing up. Check before generating.
- **Caddy reload vs restart** — reload is hot, restart drops connections.
  Use `caddy reload` only.
- **Hooks may break my own writes** — once installed, my Write tool calls
  get checked. If a legitimate write is blocked, fix the hook or add
  exemption — do not work around.
- **Image pinning post-pull** — `docker compose pull` may fetch newer
  images for *running* containers if any are :latest. Pin THEN pull.

## What U12 explicitly does NOT do
- Vault auto-unseal (deferred — needs cloud KMS or transit secret pattern,
  scope > 1 sprint, planned U13).
- Restic NAS repoint (waits for `/mnt/mycloud` mount — user-gated, planned U13).
- New pipelines or AI features.
- Phase 2 hot-tier work (already done).

## Sprint after U12 (preview)
**U13 — DR + Vault auto-unseal**
- /mnt/mycloud mount + Restic repoint (user-gated)
- Test bootstrap.sh + restore.sh dry run
- Vault auto-unseal via transit secret backend (local, no cloud)
- Image pinning audit workflow (monthly check + Telegram alert)
