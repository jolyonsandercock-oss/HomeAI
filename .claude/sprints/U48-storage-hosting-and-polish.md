# U48 — SDD migration + Wix hosting + polish

**Prereqs**: U46 + U47 ship.

**Remote vs in-person**: ~60/40. SDD mount + Authelia full forward_auth need in-person sudo. Wix integration is remote.

## Tracks

### Track 1 — Migrate data to SDD (in-person, ~1 hr)

The `/dev/sdd` 5.5TB drive is an NTFS Windows partition. Plan:

1. **In-person, sudo**:
   - `sudo apt install ntfs-3g` (already installed on Ubuntu 26.04 by default but verify)
   - `sudo mkdir -p /mnt/data`
   - `sudo mount -t ntfs-3g /dev/sdd2 /mnt/data -o uid=joly,gid=joly,umask=022`
   - Verify with `df -h /mnt/data`
   - Add to `/etc/fstab` so it mounts on boot:
     `UUID=E02A61F02A61C45E /mnt/data ntfs-3g uid=joly,gid=joly,umask=022 0 0`

2. **Naming & storage layout** (already-thought-out, document in SPEC):
   ```
   /mnt/data/
     invoices/<YYYY>/<MM>/<mid>_<safe-filename>.pdf      (~1GB/yr)
     emails/<account>/<YYYY>/<MM>/<mid>.eml              (raw email archive, optional)
     caterbook/<YYYY>/<MM>/<filename>.pdf                (Caterbook arrivals PDFs)
     touchoffice/<site>/<YYYY>/<MM>/<filename>.html      (TouchOffice scrape snapshots)
     dreaming/<YYYY>/<MM>/heuristics-<DD>.md             (Dreaming Workflow H artefacts)
     backups/<service>/<YYYY>/<MM>/<YYYY-MM-DD>.tar.gz   (Restic-backed too)
     archive/                                            (anything pre-2025)
   ```

3. **Migration** (rsync, idempotent):
   - `rsync -a --info=progress2 /home_ai/storage/invoices/ /mnt/data/invoices/`
   - Move `caterbook-samples`, `scraper-debug`, `family_docs`, `raw_emails`, `reports`, `dreaming`
   - Symlink `/home_ai/storage → /mnt/data` once migration is verified.

4. **Update docker-compose**: change bind mounts from `./storage` to `/mnt/data`.

5. **Run for 48 hours** with both old and new paths available before deleting `/home_ai/storage` originals.

**Acceptance**:
- `/mnt/data` mounted, persistent across reboot.
- `df -h /mnt/data` shows ~5.5T available.
- Existing PDF links on dashboard still resolve.
- One full backup cycle (restic nightly) completes successfully against new paths.

### Track 2 — Wix integration: host the dashboard (~3 hr, remote-doable)

Goal: host the dashboard at a Wix-managed domain so staff can access it from anywhere without needing Tailscale.

**Two-architecture options** — pick one based on Wix's actual offering for Jo's account:

**Option A — Wix as reverse proxy / static frontend** (recommended):
- Wix Studio sites can use custom code via Velo platform.
- Build a "dashboard" page in Wix that iframes / embeds our existing Mission Control HTML.
- Wix serves the page over HTTPS with auth (Wix's member area login).
- The iframe target is our Tailscale-fenced dashboard, fetched via a back-end http call from Wix's server (Velo wixFetch) — this avoids exposing the Tailscale IP publicly.
- Velo function: `getDashboardSnapshot()` calls `https://<tailscale>/api/snapshot` server-side, returns JSON. Wix renders.

**Option B — Static Wix landing + Tailscale Funnel**:
- Wix hosts only a landing page.
- Real dashboard is served via Tailscale Funnel (free, exposes a tailnet service to the public internet at `<host>.<tailnet>.ts.net`).
- Authelia + Caddy do the auth.
- Less Wix integration but simpler from our side.

**Tasks** (Option A path):
1. Probe Wix API access via Jo's `jolyon.sandercock@gmail.com` login. Document what's available on his plan.
2. Build a simple Velo backend page that proxies `/api/snapshot` server-side.
3. Auth wiring (Wix members → role check).
4. Connect Wix Studio site to a git repo (Wix Studio supports git in some plans). If Jo's plan supports it: connect `https://github.com/jolyonsandercock-oss/HomeAI` for source.

**Acceptance**:
- A Wix-hosted page renders live data from the dashboard (refresh hits the API).
- Access requires Wix login.
- (Optional) Git connection works for pushing site changes from this repo.

**Big caveat**: Wix's exact capability depends on Jo's plan. May need to upgrade (£10-30/month). Will document findings before committing.

### Track 3 — Vault auto-unseal + Authelia full forward_auth (in-person, ~1.5 hr)

Carry-over from U35. Both scripts written; both need sudo.

1. `sudo bash /home_ai/scripts/u35-vault-autounseal-bootstrap.sh` — paste 3 unseal keys, ~3 min.
2. `sudo tailscale cert <jolybox>.<tailnet>.ts.net` — provisions TLS cert.
3. Update `security/authelia-v2/configuration.yml`: `cookies.domain` + `authelia_url` → FQDN.
4. Update Caddyfile to listen on `:443` with TLS, plus `forward_auth` directives on protected paths.
5. Replace U47's basic-auth split with Authelia (single sign-on, TOTP).

**Acceptance**:
- Reboot test: Vault unseals automatically within 2 min.
- Cold browser session → protected route → Authelia portal → login → redirected back with cookie.
- `bot_instructions` ingress unaffected.

### Track 4 — Polish (~1 hr)

- Image updates (Vault 1.15.6 → 1.16.x, alertmanager v0.27 → v0.28, postgres-exporter v0.15 → v0.16) — needs harvest-pw-from-Vault dance per [[feedback_dashboard_image_rebuild]].
- Fix any remaining U35→U47 carry-over selftest failures.
- Update STATUS / STRETCH docs to reflect U48 wrap.

## Total

~6.5 hr split between in-person (Tracks 1, 3) and remote (Tracks 2, 4).
