# Home AI — Disaster Recovery runbook

**Last reviewed: 2026-05-17 (U124-D)**

## What's already in place

| What | Where | Cadence | Status |
|---|---|---|---|
| Nightly `restic` snapshot | `/home_ai/backups/restic-local/` | 03:00 daily via cron | ✓ 10 snapshots, last 2026-05-17 |
| Realm-scoped weekly backup | `/home_ai/backups/realm-scoped/` | Sundays 04:00 | ✓ |
| Synthetic-email self-test | logged to `synthetic-suite.log` | 02:30 daily | ✓ |
| Restic password file | `/home_ai/backups/.restic-pw` | static | ⚠ ONLY ON THIS HOST |

**What's backed up by `backup-nightly.sh`:**
1. `homeai` Postgres database — full `pg_dump --format=custom`
2. `home_ai_n8n_data` Docker volume — workflows + encrypted creds
3. `home_ai_vault_data` Docker volume — encrypted blob (useless without unseal keys)
4. `/home_ai/postgres` + `/home_ai/monitoring` + `/home_ai/.claude` — config files

## Critical gaps (action below)

| Gap | Risk | Action |
|---|---|---|
| **Restic password on host only** | host fire → backups unrecoverable | Print + paper-safe. See §1 |
| **Vault unseal keys location?** | Vault sealed forever after host loss | Locate + escrow. See §2 |
| **All backups same host as data** | one fire = everything | Off-site copy. See §3 |
| **Restore never actually tested** | backup might be corrupt and we'd not know | Quarterly drill. See §4 |

---

## §1 — Restic password escrow

The restic repo password is in `/home_ai/backups/.restic-pw`. **Without it, every snapshot is encrypted garbage.**

```bash
# Read the password (do this once, never again):
sudo cat /home_ai/backups/.restic-pw
```

Take that string and:
- Write it on a physical piece of paper
- Put the paper in a fireproof safe NOT in the building
- Optionally also: store in a password manager (1Password, Bitwarden) under "Home AI restic"

Do **not** commit it to git. Do **not** put it in Vault (chicken-and-egg if Vault is what you're recovering).

## §2 — Vault unseal-key escrow

Vault uses Shamir's secret sharing with 5 shares, threshold 3 (`tailscale vault status` confirms). To unseal Vault on a fresh host you need 3 of 5 keys.

**Where are the keys?** Probably in:
- `/home_ai/secrets/vault-init.json` (if it exists)
- `~/.vault-keys-on-paper.txt`
- Hard-coded in `vault-autounseal.sh`
- Lost. (Worst case — covered below.)

Find them:
```bash
ls -la /home_ai/secrets/ ~/.vault* 2>/dev/null
grep -l 'unseal\|shamir\|key_share' /home_ai/scripts/*.sh ~/.* 2>/dev/null
```

Once located:
- Print each of the 5 keys on a separate piece of paper
- Distribute physically: 2 with you (different bags), 2 with a trusted family member offsite, 1 in the pub safe
- **Do NOT keep all 5 in one place**

If keys are **lost**: Vault data is unrecoverable. Mitigation = export every Vault secret to encrypted-on-paper now, while Vault is unsealed:
```bash
TOK=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
docker exec -e VAULT_TOKEN="$TOK" homeai-vault sh -c '
  for path in $(vault kv list -format=json secret/ | jq -r ".[]"); do
    echo "=== $path ==="
    vault kv get -format=json "secret/$path"
  done
' > /tmp/vault-export-$(date +%Y%m%d).json
# Encrypt:
gpg --symmetric --cipher-algo AES256 /tmp/vault-export-*.json
# Move to USB / cold storage. Delete originals.
```

## §3 — Off-site backup destination

Today every byte of backup is on `/home_ai/backups/restic-local`. **Same disk, same host, same building.**

Three off-site options, recommended in order:

### 3a. Backblaze B2 (cheapest, ~£0.50/month for our data size)

```bash
# 1. Sign up at backblaze.com, create a B2 bucket "homeai-restic"
# 2. Create an application key (read+write to that bucket only)
# 3. Add credentials to Vault:
docker exec -e VAULT_TOKEN=$TOK homeai-vault vault kv put secret/backblaze \
  account_id=YOUR_KEY_ID \
  account_key=YOUR_APPLICATION_KEY \
  bucket=homeai-restic

# 4. Init a parallel restic repo:
export B2_ACCOUNT_ID=...
export B2_ACCOUNT_KEY=...
restic -r b2:homeai-restic:/ init -p /home_ai/backups/.restic-pw

# 5. Add to backup-nightly.sh: after local snapshot succeeds,
#    run "restic -r b2:homeai-restic:/" snapshot.

# 6. Verify:
restic -r b2:homeai-restic:/ -p /home_ai/backups/.restic-pw snapshots
```

### 3b. Tailscale-connected NAS (if you have one)

Mount the NAS at `/mnt/mycloud`, update `RESTIC_REPO` in `backup-nightly.sh` to `/mnt/mycloud/restic`. Free but only off-site relative to fire — not relative to a connected ransomware actor.

### 3c. rclone to Google Drive (free 15GB, fragile)

Last resort. Drive throttles, and rclone of an encrypted restic repo is slow. Use only if 3a/3b aren't options.

## §4 — Restore drill

A backup that's never been restored is wishful thinking. Run this quarterly.

```bash
# 1. Spin up a throwaway Postgres container:
docker run --rm -d --name dr-test-pg \
  -e POSTGRES_PASSWORD=test123 \
  -p 5433:5432 \
  postgres:16

# 2. Restore the homeai DB from the latest restic snapshot:
restic -p /home_ai/backups/.restic-pw \
  -r /home_ai/backups/restic-local \
  dump latest /tmp/dr-restore/homeai.pgdump > /tmp/dr-restore.pgdump

# 3. Load into the throwaway:
docker exec -i dr-test-pg pg_restore -U postgres -d postgres -C \
  < /tmp/dr-restore.pgdump

# 4. Verify row counts:
docker exec dr-test-pg psql -U postgres -d homeai -c "
  SELECT 'bookings' AS table, COUNT(*) FROM accommodation_bookings
  UNION ALL SELECT 'invoices', COUNT(*) FROM vendor_invoice_inbox
  UNION ALL SELECT 'guests',   COUNT(*) FROM guest_contacts
  UNION ALL SELECT 'shifts',   COUNT(*) FROM workforce_shifts;
"

# 5. Compare to live counts:
docker exec homeai-postgres psql -U postgres -d homeai -c "
  SELECT 'bookings', COUNT(*) FROM accommodation_bookings
  UNION ALL SELECT 'invoices', COUNT(*) FROM vendor_invoice_inbox
  UNION ALL SELECT 'guests',   COUNT(*) FROM guest_contacts
  UNION ALL SELECT 'shifts',   COUNT(*) FROM workforce_shifts;
"

# 6. Clean up:
docker stop dr-test-pg
rm -rf /tmp/dr-restore*
```

If row counts diverge by more than ~1% (overnight ingestion accounts for some), investigate.

## §5 — Full recovery procedure

If the host dies and you're building from scratch on new hardware:

```bash
# 0. New box: install Docker, docker-compose, restic
# 1. Recover restic password from paper escrow (§1)
# 2. Recover Vault unseal keys from paper escrow (§2)
# 3. Recover repo:
mkdir -p /home_ai/backups
echo "PASSWORD_FROM_PAPER" > /home_ai/backups/.restic-pw
chmod 600 /home_ai/backups/.restic-pw

# If off-site (B2) — copy down:
restic -r b2:homeai-restic:/ -p /home_ai/backups/.restic-pw copy \
  --to /home_ai/backups/restic-local

# 4. Restore /home_ai filesystem tree:
restic -p /home_ai/backups/.restic-pw -r /home_ai/backups/restic-local \
  restore latest --target /

# 5. Bring up just postgres + vault first:
cd /home_ai && docker compose up -d postgres vault

# 6. Unseal Vault (use 3 of the 5 paper keys):
docker exec -it homeai-vault vault operator unseal KEY_1
docker exec -it homeai-vault vault operator unseal KEY_2
docker exec -it homeai-vault vault operator unseal KEY_3

# 7. Restore Postgres dump:
docker exec -i homeai-postgres pg_restore -U postgres -d homeai \
  < /home_ai/backups/staging/homeai.pgdump

# 8. Bring up everything:
docker compose up -d

# 9. Verify with the §4 drill row-counts.
```

## §6 — Rotation + maintenance schedule

| Task | Cadence | Owner |
|---|---|---|
| `redo-google-oauth.sh diagnose` (catches token expiry early) | Daily 06:00 cron — already set | automated |
| Restore drill (§4) | Quarterly | Jo, calendar reminder |
| Verify off-site copy current (`restic snapshots`) | Weekly | automated check + Telegram alert if stale |
| Rotate Vault root token | Yearly | Jo |
| Rotate Postgres `homeai_readonly` password | Yearly | Jo |
| Rotate Anthropic API key | Yearly | Jo |
| Re-print + redistribute Vault unseal keys | Yearly | Jo |
| Audit `secret/*` paths for unused entries | Bi-annually | Jo |

## §7 — Immediate action items (you should do these this week)

1. **§1** — print the restic password on paper, put in fireproof safe / safe-deposit
2. **§2** — find Vault unseal keys, print on 5 separate slips, distribute (2 at home in different bags, 2 with family offsite, 1 in pub safe)
3. **§3a** — set up Backblaze B2 + add `restic -r b2:` snapshot to nightly cron. £0.50/month, single biggest DR upgrade
4. **§4** — run the restore drill once now while everything is fresh in mind. Add a calendar reminder for July, October, January
