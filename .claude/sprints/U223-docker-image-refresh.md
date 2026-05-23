# U223 — Stale Docker image refresh (Vault, alertmanager, postgres-exporter)

**Prereqs**: Jo at the console or remote with attention available; Restic backup < 1h old; afternoon window (avoid morning cron storm at 02:15-04:00).

**Realm**: work. Infrastructure security maintenance is WORK-side hygiene.

**Remote vs in-person**: 90% remote, 10% in-person standby. Each upgrade is a one-line image-pin change in `docker-compose.yml` plus a recreate. Vault is the highest-risk; rollback is fast (revert the pin) but Jo should be reachable.

**Why this sprint exists**: Three images flagged stale during U35 close-out (per memory entry that's now archived) — Vault 1.15.6, alertmanager v0.27, postgres-exporter v0.15. All >18 months old. CVEs accumulated; bug fixes definitely have. Image-drift monthly cron continues to flag them. This sprint clears the warning bin in one focused session.

## Tracks

### T1 — Pre-flight: capture current state + verify backups (~10 min)

**Build**:
- `docker compose ps --format json > /tmp/u223-pre.json` (record current image hashes)
- `restic snapshots | head` confirm a backup within the last hour
- Note current Vault version: `docker exec homeai-vault vault status | grep Version`

**Acceptance**:
- /tmp/u223-pre.json exists with all three target services listed
- Most-recent Restic snapshot < 1h old

---

### T2 — Bump postgres-exporter (~15 min, lowest risk first)

**Realm**: work.

**Build**:
- Edit `docker-compose.yml` — change `prometheuscommunity/postgres-exporter:v0.15.0` → `:v0.18.0` (or latest stable; check Dockerhub tags first)
- `docker compose up -d --no-deps postgres-exporter`
- Wait 60s; check Prometheus is still scraping it:
  ```
  curl -s http://localhost:9100/metrics | grep -c pg_stat
  ```
  Should return >10.

**Acceptance**:
- `docker ps` shows the new image tag
- Postgres metrics still visible in Grafana / Prometheus

**Rollback**: revert the pin in docker-compose.yml, `docker compose up -d --no-deps postgres-exporter`

---

### T3 — Bump alertmanager (~15 min, low risk)

**Realm**: work.

**Build**:
- Edit `docker-compose.yml` — bump `prom/alertmanager:v0.27.0` → latest v0.28.x
- `docker compose up -d --no-deps alertmanager`
- Test by triggering a known synthetic alert OR by checking `/api/v2/status`:
  ```
  curl -s http://localhost:9093/api/v2/status | jq '.versionInfo'
  ```

**Acceptance**:
- New version reported
- No "config validation" errors in `docker logs homeai-alertmanager --tail=50`

**Rollback**: revert pin + recreate

---

### T4 — Bump Vault (HIGHEST RISK — careful) (~45 min)

**Realm**: work + owner.

**Build**:
- Read Vault upgrade notes for 1.15.x → target version (check breaking changes between versions; Vault has a track record of removing deprecated commands at major bumps)
- Target: 1.16.x or 1.17.x (NOT a major jump to 2.x). Verify on hashicorp/vault Dockerhub
- Edit `docker-compose.yml` — change `hashicorp/vault:1.15.6` → `:1.17.x` (or chosen target)
- Pre-stop: take a fresh Restic snapshot of `vault/data/` explicitly
- `docker compose up -d --no-deps homeai-vault`
- Vault will be **sealed** after restart; unseal with the 3 keys (or auto-unseal if U221 has shipped)
- Smoke test:
  ```
  docker exec homeai-vault vault status        # version + sealed:false
  docker exec homeai-vault vault read secret/data/anthropic  # secret readable
  ```
- Wait 5 min, watch `docker logs homeai-vault --tail=50` for any new errors
- Check downstream services that read Vault (bot-responder, build-dashboard, n8n) — restart any that show stale-token errors

**Acceptance**:
- `vault status` shows new version, unsealed
- `secret/data/anthropic` readable
- Bot-responder responds to a `/api/bot/ask` test call (proves Vault-side anthropic key fetch still works)
- n8n quick workflow execution succeeds

**Rollback**:
- Revert pin to 1.15.6
- `docker compose up -d --no-deps homeai-vault`
- Re-unseal
- If Vault data format incompatibility shows up: restore `vault/data/` from the pre-bump Restic snapshot

---

### T5 — Update image-drift expectations + commit (~10 min)

**Build**:
- Note in `TECH-DEBT.md`: mark all three as ✓ resolved with date
- `git commit -am "U223: refresh stale images — vault, alertmanager, postgres-exporter"`
- The image-drift cron will pick up the new dates automatically

**Acceptance**:
- `git log -1` shows the commit
- Next monthly image-drift run flags fewer than 3 stale images

---

## What this sprint does NOT do

- Does not upgrade other services (n8n, postgres, ollama, paperless...) — those have their own dependency chains and should be sprint'd separately
- Does not change Vault's storage backend, ACL policies, or AppRole config (see [[U221]])
- Does not enable any new Vault features (Vault Enterprise, performance replicas)

## Follow-on sprints

- **U??? — n8n upgrade** (separate sprint, may break workflow JSON format — needs care)
- **U??? — image-drift CI automation** — wire image-drift cron to auto-open `bot_instructions` rows so this kind of debt is surfaced before 18 months pass
