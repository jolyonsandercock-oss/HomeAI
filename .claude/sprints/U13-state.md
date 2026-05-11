# U13 — DR + Vault Auto-Unseal + Monthly Image Audit + User-Gated Scripts

**Trigger:** Starts after U12 (autonomous portion closed). Carries forward
hardening theme — closes the rest of dashboard `debt.yaml` and Phase 2 gates.

**User direction:** "write the necessary scripts for me and go ahead" — favour
script-driven workflows the user can run with prompts, over copy-paste blocks.

## Stages

### A — Monthly image-audit n8n workflow  *(autonomous, ~30 min)*
Build `image-audit-monthly-v1.json`. Once a month, hit Docker Hub registry
API for each pinned image, compare with the current digest, Telegram-notify
when an image is more than N+ patch versions behind. Closes the "image
pinning audit cadence" gap that motivated U12 Stage B.

### B — DR scripts dry-run review  *(autonomous, ~30 min)*
Read `backup-all.sh` / `bootstrap.sh` / `restore.sh` / `backup-nightly.sh`.
Identify gaps (NAS path hard-coded? cron commented? Vault unseal flow?).
Apply small fixes that don't change the contract. Document remaining
NAS-dependent gaps for Stage C.

### C — Write `u13-mount-nas.sh`  *(scripted user-gated)*
User runs with sudo prompt. Discovers /mnt/mycloud target, prompts for
SMB or NFS, writes fstab entry, mounts, repoints Restic repo, runs first
sync, validates with `restic snapshots`. Self-aborts if any step fails.

### D — Write `u13-install-hooks.sh`  *(scripted user-gated)*
User runs to install PreToolUse hooks in their `~/.claude/settings.json`.
Backs up existing settings, merges hooks block, runs two negative-tests,
prints pass/fail. (Closes U12 Stage A which I cannot self-modify.)

### E — Vault auto-unseal scaffolding  *(autonomous, partial)*
Set up Vault transit secret backend on a separate Vault instance OR document
the local-key auto-unseal pattern. Final cutover is invasive (Vault reinit)
so saved as a runnable script `u13-bootstrap-auto-unseal.sh` for user.

### F — Selftest + sprint close  *(autonomous, ~15 min)*
`u13-selftest.sh`: image-audit workflow active, scripts present + executable,
DR scripts pass shellcheck. Telegram update.

## Out of scope
- Actually mounting NAS / re-initialising Vault — both require user hands.
- Authelia rollout — already has `authelia-bootstrap.sh`; tracked as U12 Stage D.
- New pipelines or AI features.

## Estimated total
- Autonomous: ~75 min
- User scripts (run by Jo): ~30 min combined
