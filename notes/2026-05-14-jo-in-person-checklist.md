# In-Person Checklist — JolyBox

**For the next session at the physical box.** Everything below needs either
sudo or hardware access and so cannot run from Claude. Items are independent
unless marked; run in order or skip.

Verify date: 2026-05-14. Reconfirm `crontab -l | grep -c u50\|u51\|u47e` ≥ 4
before starting — that's how you know the autonomous side is still healthy.

---

## 1. Install Claude Code hooks (~2 min)

Why: `no-secrets-in-files.sh` + `sql-rules.sh` block accidental commits of
hex secrets in YAML configs (memory: `feedback_homeai_pre_push_scan`) and
enforce RLS / HMAC patterns. They exist and have negative-tested but the
agent cannot install them into its own settings.

```bash
bash /home_ai/.claude/scripts/u13-install-hooks.sh
```

Accept: `jq '.hooks.PreToolUse | length' ~/.claude/settings.json` ≥ 1.

If the merge fails, the installer prints a diff and backs up the prior
settings.json to `~/.claude/settings.json.bak.YYYYMMDD-HHMM`.

---

## 2. NAS mount decision (~5 min once decided)

Why: restic snapshots are local-only. A house fire = lost backups.
GitHub off-host-backup (U26) covers text configs but not data.

```bash
sudo bash /home_ai/.claude/scripts/u13-mount-nas.sh
```

Interactive SMB/NFS prompt. Idempotent. Will fail gracefully if no NAS
on the network — that's OK, postpone and document in Telegram with
`nas: postponed until <date>` so it stops re-flagging.

Accept: `mount | grep -q /mnt/nas` AND `df -h /mnt/nas` shows free space.

---

## 3. SDD migration (~60–90 min, hardware swap)

Why: Postgres + restic + ollama models will outgrow the SATA SSD inside a
year. Better to move data dir before it hurts.

**Sequence**:
1. Power down: `cd /home_ai && docker compose stop && sudo shutdown -h now`
2. Physically install new NVMe drive
3. Boot, partition, format ext4
4. `sudo mkdir /mnt/sdd && sudo mount /dev/nvme0n1p1 /mnt/sdd`
5. `sudo rsync -aHAX --info=progress2 /home_ai/postgres/data/ /mnt/sdd/postgres/`
6. Edit `/home_ai/docker-compose.yml`: rebind postgres volume `/home_ai/postgres/data` → `/mnt/sdd/postgres`
7. Add to `/etc/fstab`: `UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p1) /mnt/sdd ext4 defaults,nofail 0 2`
8. `cd /home_ai && docker compose up -d postgres`
9. Verify: `docker exec homeai-postgres psql -U postgres -d homeai -c "SELECT COUNT(*) FROM emails"` matches pre-migration count

Accept: postgres healthy, row counts match within 0, `df -h /mnt/sdd`
shows expected free space.

Rollback: if rsync hash differs, revert compose.yml change and remount old volume.

---

## 4. Authelia full forward_auth + Vault reconcile (~30 min)

Why: SSO works today because Authelia reads its file-rendered config, but
Vault's stored secrets don't match (memory:
`feedback_authelia_cookie_domain`). Cosmetic until a future rotation,
but blocks U48's clean rotation flow.

**Sequence**:
1. `cd /home_ai && bash scripts/authelia-bootstrap.sh` — answer **Y**
   at "Import existing into Vault?" prompts
2. `docker compose restart authelia`
3. Uncomment in `docker-compose.yml`:
   - the `authelia:` service block (currently commented out)
   - the `caddy-forward-auth` directive blocks under each protected route
4. Edit `security/caddy/Caddyfile`: wire `forward_auth` to
   `/dashboard` and `/metabase` only — not `/auth/` or `/healthz`
5. `docker compose up -d caddy authelia`
6. From a fresh browser: visit `http://100.104.82.53/dashboard` →
   should redirect to Authelia login → after login lands at dashboard.

Accept: Authelia login appears on first visit to /dashboard; cookie
follows across pages; /healthz still answers without auth.

---

## 5. Caddy routes for /dashboard, /metabase, /auth/ (~30 min)

May already be done in step 4. If not, edit `security/caddy/Caddyfile`
to add `handle_path /dashboard/*`, `/metabase/*`, `/auth/*` reverse_proxy
blocks (similar to existing /dashboard pattern). `docker compose
exec caddy caddy reload --config /etc/caddy/Caddyfile` to apply
without restarting.

---

## Optional same-trip housekeeping

- `df -h` — confirm no volume > 80% full
- `docker system prune -af --volumes` — only if disk pressure
- `git -C /home_ai status` — should be clean; if not, `bash scripts/u26-push-backup.sh`

---

When done: edit this file's first line to `# In-Person Checklist — done
YYYY-MM-DD` and run `bash scripts/u26-push-backup.sh` so the closure is
recorded off-host.
