## Claude Code Storage Migration — Analysis + Plan v2

Read AGENTS.md for context. You are on P620 (128GB RAM, RTX 3060, Ubuntu). This is Plan Mode — do NOT implement anything yet.

### THE PROBLEM

NVMe SSD (/dev/nvme0n1p2, 915GB, ~396GB free) holds everything. Growth is steady. /mnt/shared_storage is a 5.5TB spinning HDD (3M used, 5.5T free) that is almost entirely idle. Key consumers on NVMe include:

- ~/.steam/ — Steam games, likely the single largest consumer
- ~/.claude/ — Claude Code session history, file-history, backups (182MB+)
- /var/lib/docker/ — ALL Docker volumes, images, containers, overlay2 layers (this is the architectural elephant — Postgres, Qdrant, Ollama, Vault, n8n, Paperless, Prometheus, Grafana ALL store data here)
- /home_ai/storage/ — bank statements, PDFs, CSVs, tarballs
- /home_ai/.claude/ — project-level Claude data
- ~/.npm/, ~/.cache/, ~/.nvm/ — dev tool caches
- systemd journal + /var/log/

### THE GOAL

Move bulk/clutter data to the HDD. Keep only speed-critical data on NVMe. Claude Code MUST continue working. Docker Compose MUST come up clean.

### PRE-FLIGHT CHECKS (run these first)

```bash
# Confirm HDD is healthy and writable
lsblk -f /mnt/shared_storage
smartctl -H /dev/sdX  # whichever device backs /mnt/shared_storage
df -h /mnt/shared_storage

# Confirm Docker root location
docker info | grep "Docker Root Dir"
```

### AUDIT CHECKLIST (run ALL of these, report sizes)

**User home directories:**
```bash
du -sh ~/.steam ~/.claude ~/.npm ~/.cache ~/.nvm ~/.hermes ~/.ollama ~/.local 2>/dev/null
```

**Home AI directories:**
```bash
du -sh /home_ai/storage /home_ai/.claude /home_ai/services /home_ai/postgres 2>/dev/null
```

**Docker volumes (every named volume and its size):**
```bash
for vol in $(docker volume ls -q); do
    mp=$(docker volume inspect "$vol" --format '{{.Mountpoint}}')
    size=$(du -sh "$mp" 2>/dev/null | cut -f1)
    echo "$vol  $size  $mp"
done
```

**Docker overlay2 (images + container layers — this can be 20-50GB+):**
```bash
du -sh /var/lib/docker/overlay2 2>/dev/null
```

**System logs:**
```bash
journalctl --disk-usage
du -sh /var/log
```

**Any large hidden directories in home:**
```bash
du -sh ~/.* 2>/dev/null | sort -rh | head -20
```

### DOCKER VOLUME RELOCATION — CRITICAL ARCHITECTURAL NOTE

You CANNOT use `ln -s` to relocate Docker volumes under /var/lib/docker/volumes/. Docker's volume driver and overlayfs will not follow symlinks. Options for Docker data relocation:

**Option A: Move individual volumes (recommended)**
1. `docker-compose down` the relevant service
2. `rsync -aAXv /var/lib/docker/volumes/VOLNAME/_data/ /mnt/shared_storage/docker-volumes/VOLNAME/`
3. Verify: `rsync -aAXvn --checksum /var/lib/docker/volumes/VOLNAME/_data/ /mnt/shared_storage/docker-volumes/VOLNAME/` (dry-run, should show no differences)
4. Update docker-compose.yml to mount from HDD path:
   ```yaml
   volumes:
     # was: - volume_name:/container/path
     # becomes:
     - /mnt/shared_storage/docker-volumes/VOLNAME:/container/path
   ```
5. Remove the old Docker volume: `docker volume rm VOLNAME`

**Option B: Move entire Docker data-root (nuclear option)**
Edit /etc/docker/daemon.json, set `"data-root": "/mnt/shared_storage/docker"`, restart Docker. Moves EVERYTHING — Postgres, Qdrant, everything. Only use if you accept the performance trade-off for all services.

**Option C: Bind-mount per volume (advanced)**
Stop Docker, move volume directories, create bind mounts in /var/lib/docker/volumes/. Complex, fragile across Docker restarts.

RECOMMENDATION: Option A for bulk volumes (Paperless media, Prometheus, Grafana, n8n data). Keep Postgres, Qdrant, Vault on NVMe as named volumes (don't move them).

### YOUR OUTPUT

Produce /home_ai/.hermes/storage-migration-plan.md with:

**Section A: Full NVMe Audit**
Table: Path | Size | Growth Rate | Speed Critical? | Verdict (KEEP/MOVE/ARCHIVE/DELETE)

Example row:
| /home/joly/.steam | 177G | static | No (games load once) | MOVE |

**Section B: HDD Layout**
Proposed structure under /mnt/shared_storage/. For each moved item, what path it gets on the HDD.

**Section C: Migration Commands**
Every command needed, in order, grouped by service. Include:
- `docker-compose stop <service>` before touching its volumes
- `rsync -aAXv <source> <dest>` for data moves (NOT `mv` or `cp` — rsync preserves everything and can be verified)
- `rsync -aAXvn --checksum <source> <dest>` for verification (dry-run, zero differences = success)
- `docker-compose up -d <service>` after confirming
- For non-Docker directories: `ln -s <REAL_PATH_ON_HDD> <SYMLINK_AT_ORIGINAL_LOCATION>` per `ln -s` syntax

**Section D: Rollback**
For each move, the exact commands to put everything back. Test that the rollback works by running the verification rsync in reverse.

**Section E: Risks**
What breaks if done wrong. What needs a backup first. What services need stopping and for how long. HDD SMART status requirement.

**Section F: Impact Estimate**
SSD used before → after. HDD used before → after. Projected SSD fill rate change.

### CONSTRAINTS

- Claude Code MUST continue working. If moving ~/.claude/, do it while Claude is not running.
- Docker Compose MUST come up clean. Test with `docker-compose up -d` after every service move.
- PostgreSQL stays on NVMe (IOPS-critical). Do NOT move it.
- Qdrant and Vault likely stay on NVMe (latency-sensitive).
- Ollama models: Docker volume at home_ai_ollama_data. Model loading is sequential read — HDD should be fine for 7B-14B models. Move candidate.
- Paperless media (scanned bank statements): large, low-speed-need — move.
- Prometheus TSDB: high write volume, HDD may cause issues — investigate, flag as risky.
- Use rsync EVERYWHERE (not mv, not cp). Preserve permissions with -aAX.
- Verify before deleting originals. Dry-run rsync with --checksum must show zero differences.
- Include a rollback command for every move.
- ./AGENTS.md is at /home_ai/AGENTS.md (the main one). Also read /home/joly/AGENTS.md.
- /home_ai/docker-compose.yml is the authoritative compose file. Check it for volume mounts.

### DO NOT EXECUTE

Plan Mode only. Output the analysis document, then stop.
