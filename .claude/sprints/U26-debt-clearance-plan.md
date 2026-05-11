# U26 — Tech-debt clearance, broken into chunks for your input

Total debt items at start of sprint: **8**. Of these, 5 already have runnable
scripts from U13. 3 are new + need fresh scripts. The orchestrator
(`u26-menu.sh`) shows you what's done vs pending whenever you run it.

## How to use this

Run the menu and pick a chunk:
```bash
bash /home_ai/.claude/scripts/u26-menu.sh
```

Each chunk is self-contained, interactive, idempotent, and prints what it
just did. Run them in any order, in any number of sessions.

## Chunk catalogue

| # | Item | Script | Run as | Estimated time |
|---|---|---|---|---|
| 1 | Wake the system after sleep | `./start.sh` (existing) | you | 60s |
| 2 | Post-wake autonomous cleanup | `u26-post-wake.sh` (new) | you | 30s |
| 3 | Install PreToolUse hooks | `u13-install-hooks.sh` (existing) | you (not root) | 2 min |
| 4 | Children real data | `u26-children.sh` (new) | you | 5 min |
| 5 | Forward sample emails (Caterbook + EPoS) | `u26-capture-samples.sh` (new) | you | 10 min |
| 6 | Mount NAS + repoint Restic | `u13-mount-nas.sh` (existing) | sudo | 5 min |
| 7 | Bootstrap single-passphrase Vault unseal | `u13-bootstrap-auto-unseal.sh` (existing) | sudo (once) | 5 min |
| 8 | Bootstrap Authelia 2FA | `u26-prep-authelia.sh` then `scripts/authelia-bootstrap.sh` (new + existing) | sudo + you | 30 min |
| 9 | Backup-all git push (off-host config history) | `u26-setup-git-remote.sh` (new) | you | 15 min |

## Order of priority

If you only have 15 minutes, do **#1 → #2 → #3**.
That restores ingestion, re-enables Vault metrics, locks down hooks. Highest
operational value per minute.

If you've got an hour, add **#4 + #5 + #6**. The first two close ongoing data
quality gaps; #6 is real DR.

The rest (#7, #8, #9) are infrastructure hardening — schedule when you can
spare a focused 30-min block each.

## State tracking

After each chunk runs, the orchestrator inspects the system and shows the
debt list with check marks. No manual book-keeping. The dashboard's
`debt.yaml` is also updated by the scripts where applicable.

## Anti-scope (still on me, not you)

- LoRA fine-tune (Phase 3, blocked on GPU planning)
- Storyblok (Phase 5, needs design decisions)
- Calendar/Drive/Sheets pipelines (Phase 3)
- WhatsApp / Garmin integrations (Phase 4)
- Anomaly tuning once we have a week of real EPoS data
