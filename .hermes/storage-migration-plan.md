# Claude Code Storage Migration — Plan v2 (analysis)

**Host:** P620, NVMe `/dev/nvme0n1p2` (915 G, **474 G used / 395 G free, 55 %**) → spinning HDD `/dev/sdd1` (ext4, label HOMEAI_DATA, **5.5 T, 3 M used**, mounted `/mnt/shared_storage`). Docker root: `/var/lib/docker` (on NVMe). Audited read-only 2026-06-07. **Plan only — nothing executed.**

---

## TL;DR — the prompt's premise is half right; reclaim before you migrate

The framing ("move bulk data to the HDD; Docker volumes are the elephant") leads with the riskiest, highest-effort lever. The audit says the opposite is available first:

| Lever | Frees | Risk | Effort |
|---|---|---|---|
| **`docker buildx prune`** (build cache 185.8 G, **170.7 G reclaimable**) | **~170 G** | ~zero | 1 command |
| `journalctl --vacuum-size=200M` (journal 3 G) | ~2.5 G | zero | 1 command |
| `npm cache clean` + clear `~/.cache` | ~7 G | zero | 2 commands |
| `docker image prune` (dangling, 2.85 G) | ~2.8 G | zero | 1 command |
| **Reclaim subtotal** | **~182 G** | — | minutes |

Reclaiming ~182 G takes NVMe from **474 G → ~292 G used (55 % → ~32 %)** with **no volume relocation, no service downtime, no HDD dependency**. The build cache alone (170 G — bloated by this session's image rebuilds) is larger than the entire Steam library. **Do Phase 0 first; then decide whether migration is even needed.** It probably isn't, this quarter.

Migration (Phase 1+) is still worth doing for the *truly* static bulk — Steam (177 G) and Ollama models (20.6 G) — to push the steady-growth ceiling out by years. But it's elective, not urgent, once Phase 0 runs.

---

## Section A — Full NVMe Audit

| Path | Size | Growth | Speed-critical? | Verdict |
|---|---|---|---|---|
| **Docker build cache** | **185.8 G (170.7 G reclaimable)** | spikes on every `docker build` | No | **RECLAIM** (`buildx prune`) |
| **Docker images** (47, 34 active) | 221.3 G* | grows with new services | Partly (active layers) | **RECLAIM dangling (2.85 G)**; rest only via data-root move (Phase 2) |
| `~/.steam` | 177 G | static (games load once) | No | **MOVE** (HDD) |
| Docker named volume `ollama_data` | 20.6 G | grows per model pulled | No (sequential read) | **MOVE** (HDD, Option A) |
| `/var/log` + journal | 3.5 G + 3 G | steady | No | **RECLAIM** (vacuum) |
| Docker volume `postgres_data` | 3.10 G | steady | **YES (IOPS)** | **KEEP (NVMe)** |
| anon volume `773a90bb…` | 2.46 G | ? | investigate | **IDENTIFY** before acting |
| `~/.hermes` | 2.1 G | session-driven | No | KEEP (or ARCHIVE old) |
| Docker volume `open_webui_data` | 1.12 G | slow | No | MOVE (HDD) — optional |
| `~/.cache` | 1.3 G | regrows | No | **DELETE** (regenerates) |
| `~/.npm` | 6.6 G | regrows | No | **RECLAIM** (`npm cache clean`) |
| `~/.local` | 1.1 G | slow | mixed | KEEP |
| `~/.nvm` | 515 M | static | No (toolchain) | KEEP (small) |
| Docker volume `paperless_media` | 177 M | **grows with every scan** | No | MOVE (HDD) — pre-emptive |
| `/home_ai/storage` | 7.6 G | grows (PDFs/CSVs) | No | ARCHIVE old / MOVE |
| `/home_ai/backups` | 1.5 G | grows | No | MOVE/ARCHIVE (HDD) |
| Docker volume `postgres`-adjacent small (n8n 36 M, grafana 54 M, paperless_data 18 M, qdrant 357 B, vault 67 K, caddy, alertmanager) | < 150 M total | low | mixed | KEEP (too small to bother) |
| `~/.claude` | 240 M | session history | mild (read on resume) | **KEEP (NVMe)** — small; don't move |
| Prometheus TSDB | **anonymous volume** (likely `47d0164…` 673 M) | **high write** | **YES (write IOPS)** | **KEEP (NVMe)**; give it a *named* volume (see Risks) |

\* `docker system df` SIZE double-counts shared layers; true on-disk is less. The 170.7 G build-cache *reclaimable* figure is real.

**Could not audit without root (REQUIRED manual pre-flight):**
```bash
sudo smartctl -H /dev/sdd          # HDD health — MUST be PASSED before trusting 5.5T of data to it
sudo du -sh /var/lib/docker/overlay2 /var/lib/docker   # true Docker on-disk size (for Phase 2 sizing)
```

---

## Section B — HDD Layout (`/mnt/shared_storage/`)

```
/mnt/shared_storage/
├── scans/inbox/              # ALREADY here (paperless consume bind) — unchanged
├── docker-volumes/           # relocated named volumes (Option A)
│   ├── ollama_data/
│   ├── open_webui_data/
│   └── paperless_media/
├── steam/                    # relocated Steam library
├── home_ai-archive/
│   ├── storage/              # aged PDFs/CSVs from /home_ai/storage
│   └── backups/              # /home_ai/backups
└── .migration-backups/       # safety copies taken before any destructive step
```
Postgres, Qdrant, Vault, Prometheus, n8n, Grafana, Caddy volumes **stay on NVMe** (not represented here).

---

## Section C — Migration Commands (in order)

### Phase 0 — Reclaim (do this first; no downtime, frees ~182 G)
```bash
# 0.1 Docker build cache — the big one (~170 G). Safe: only cached build layers.
docker buildx prune -af
# (if not using buildx builder:) docker builder prune -af

# 0.2 Dangling images (~2.85 G). Safe: only untagged/unreferenced.
docker image prune -f

# 0.3 Journal: cap at 200 MB (~2.5 G freed). Safe.
sudo journalctl --vacuum-size=200M

# 0.4 Dev caches (regenerate on demand). Safe.
npm cache clean --force
rm -rf ~/.cache/*

# 0.5 Re-measure
df -h /
docker system df
```
**Stop here and reassess.** If NVMe is now ~32 % used, Phases 1–2 are elective.

### Phase 1 — Move static bulk (elective; biggest single item = Steam)
```bash
# 1.1 STEAM (177 G) — do with Steam CLOSED. Prefer Steam's own "Move install folder"
#     (Settings → Storage → add /mnt/shared_storage/steam library, move games).
#     If relocating the whole dir manually instead:
#     (Steam must be fully quit; verify: pgrep -a steam)
mkdir -p /mnt/shared_storage/steam
rsync -aAXv ~/.steam/ /mnt/shared_storage/steam/
rsync -aAXvn --checksum ~/.steam/ /mnt/shared_storage/steam/   # dry-run: ZERO diffs = ok
# only after zero-diff:
mv ~/.steam ~/.steam.premigration && ln -s /mnt/shared_storage/steam ~/.steam
# (symlink is fine for Steam — it is NOT a Docker volume)

# 1.2 home_ai aged storage + backups (HDD) — these are plain dirs, symlink-safe
mkdir -p /mnt/shared_storage/home_ai-archive/{storage,backups}
rsync -aAXv /home_ai/backups/ /mnt/shared_storage/home_ai-archive/backups/
rsync -aAXvn --checksum /home_ai/backups/ /mnt/shared_storage/home_ai-archive/backups/
# only after zero-diff: mv /home_ai/backups /home_ai/backups.pre && ln -s /mnt/shared_storage/home_ai-archive/backups /home_ai/backups
```

### Phase 2 — Relocate Docker named volumes (Option A; per-volume downtime ~minutes)
Per the prompt's correct warning: **no symlinks under `/var/lib/docker/volumes/`** — change the compose mount to a host path. Do ONE volume at a time, verify, then next.

```bash
cd /home_ai
mkdir -p /mnt/shared_storage/docker-volumes

# --- ollama_data (20.6 G) ---
docker compose stop ollama
sudo rsync -aAXv  /var/lib/docker/volumes/home_ai_ollama_data/_data/  /mnt/shared_storage/docker-volumes/ollama_data/
sudo rsync -aAXvn --checksum /var/lib/docker/volumes/home_ai_ollama_data/_data/  /mnt/shared_storage/docker-volumes/ollama_data/   # ZERO diffs
# edit docker-compose.yml:  ollama service
#   was:    volumes: [ollama_data:/root/.ollama]
#   become: volumes: ["/mnt/shared_storage/docker-volumes/ollama_data:/root/.ollama"]
docker compose up -d ollama
docker compose exec ollama ollama list      # verify models present
# only after verified: docker volume rm home_ai_ollama_data

# --- open_webui_data (1.1 G) — same pattern, mount /app/backend/data ---
# --- paperless_media (177 M) — same pattern, mount /usr/src/paperless/media ---
```
After all Phase-2 moves, also remove the now-unused names from the compose top-level `volumes:` block.

---

## Section D — Rollback (per move)

- **Phase 0:** nothing to roll back — reclaimed data regenerates (build cache rebuilds on next `docker build`; caches refill; journal regrows).
- **Steam (1.1):** `rm ~/.steam && mv ~/.steam.premigration ~/.steam`. (Keep `.premigration` until a successful game launch.)
- **home_ai dirs (1.2):** `rm /home_ai/backups && mv /home_ai/backups.pre /home_ai/backups`.
- **Docker volume (Phase 2), e.g. ollama:**
  ```bash
  docker compose stop ollama
  # revert the docker-compose.yml mount line back to  ollama_data:/root/.ollama
  # recreate the named volume + copy data back:
  docker volume create home_ai_ollama_data
  sudo rsync -aAXv /mnt/shared_storage/docker-volumes/ollama_data/ /var/lib/docker/volumes/home_ai_ollama_data/_data/
  docker compose up -d ollama
  ```
  Do **not** delete the HDD copy until NVMe-restored service is verified. Reverse-verify with `rsync -aAXvn --checksum` in the opposite direction = zero diffs.

---

## Section E — Risks

1. **HDD health is unverified.** `sudo smartctl -H /dev/sdd` MUST return PASSED before trusting bulk data to it. A single spinning disk with no RAID = one failure domain; keep `.migration-backups/` until verified and consider the HDD itself non-authoritative (it should not hold the *only* copy of anything irreplaceable — backups still need an off-host target).
2. **Postgres / Qdrant / Vault stay on NVMe.** Moving Postgres to HDD would tank IOPS and risk corruption under load — do NOT. (Prompt agrees.)
3. **Prometheus has no named data volume** — its TSDB is on an *anonymous* volume (likely `47d0164… 673 M`). It is high-write and must stay on NVMe. If you ever want it relocatable, first give it a **named** volume (`prometheus_data:/prometheus`) on NVMe — don't move it to HDD (write-amplification on spinning disk causes scrape stalls; prompt flagged this correctly).
4. **No symlinks for Docker volumes.** Only the compose-mount-path method (Option A). Symlinks under `/var/lib/docker/volumes/` silently break. Symlinks ARE fine for non-Docker dirs (Steam, `/home_ai/backups`).
5. **`~/.claude` while Claude runs.** It's only 240 M and read on resume — recommend **KEEP on NVMe** (moving it for 240 M isn't worth the "Claude must be stopped" hazard the prompt calls out).
6. **rsync trailing slashes** matter (`src/` → contents into dest). Always dry-run `--checksum` to zero diffs before deleting any original. Use `mv original original.pre` (not `rm`) as the "delete" step until verified.
7. **`docker volume rm` is irreversible** — only after the service is up on the new path AND verified (e.g. `ollama list` shows models).
8. **Identify the 2.46 G anonymous volume** (`773a90bb…`) before any prune; `docker volume prune` would delete unused anonymous volumes — confirm nothing needs it first.

---

## Section F — Impact Estimate

| | NVMe used | NVMe free | % |
|---|---|---|---|
| **Now** | 474 G | 395 G | 55 % |
| After **Phase 0** (reclaim ~182 G) | **~292 G** | **~625 G** | **~32 %** |
| After Phase 1 (Steam 177 G + home_ai 9 G) | ~106 G | ~810 G | ~12 % |
| After Phase 2 (ollama 20.6 G + open_webui 1.1 G + paperless_media 0.2 G) | ~84 G | ~830 G | ~9 % |

**Fill-rate change:** Phase 0 is a one-time ~182 G recovery but build cache *will* regrow (cap it: run `docker buildx prune -af` on a weekly cron, or set BuildKit `--cache-to` limits). Phases 1–2 remove the *static* 177 G Steam + the slow-grow Ollama/Paperless, so the steady NVMe growth that remains is Postgres + logs + session data — years of runway at the observed rate.

**Recommendation:** Execute **Phase 0 now** (reclaims ~182 G, zero risk, no downtime) and re-measure. Schedule the weekly `buildx prune`. Treat Phases 1–2 as elective; do Steam next if you want NVMe headroom for games, and Ollama only if model storage starts climbing. Verify HDD SMART health before relying on it for anything.
