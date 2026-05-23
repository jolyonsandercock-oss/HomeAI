# U221 — Vault auto-unseal + AppRole token migration

**Prereqs**: Jo at the JolyBox console (or on Tailscale SSH with sudo); Vault running and unsealed currently; recent backup of `vault/data/` (or full Restic snapshot < 1h old).

**Realm**: work + owner. Vault holds secrets for all realms; the auto-unseal mechanism itself is owner-only.

**Remote vs in-person**: 50% remote, 50% in-person. The `sudo` for the systemd unit can't be done from a Claude Code session (no interactive tty); the AppRole work afterwards is all remote.

**Why this sprint exists**: Vault has been on the long-lived root token + manual-unseal-on-boot pattern since Phase 1. Two consequences:
1. JolyBox reboots require Jo at the keyboard with the 3 unseal keys before any service that uses Vault (n8n, bot-responder, build-dashboard, ...) can come back up. Friction.
2. The n8n `vault-token-header` credential (id `0wPA4DCDuehPC9Mf`) is a long-lived root token. Per [[feedback_homeai]] the "never write secrets to files" rule treats this token as out-of-policy.

Closes a TECH-DEBT.md entry that's been open since Phase 2.

## Tracks

### T1 — Vault auto-unseal bootstrap (~45 min, IN-PERSON)

**Realm**: owner.

**Build**:
- Jo runs: `sudo bash /home_ai/scripts/u35-vault-autounseal-bootstrap.sh`
  - This installs the systemd unit + transit-encrypted unseal key blob
- Reboot JolyBox once during a quiet window (no live cron near boot time)
- Confirm Vault unsealed within 30s of boot without manual intervention:
  ```
  systemctl status vault-autounseal
  docker exec homeai-vault vault status | grep Sealed
  ```

**Acceptance**:
- `Sealed false` shown without any manual `vault operator unseal` invocations
- All Vault-dependent containers come up healthy after reboot (check `docker ps --format '{{.Names}}\t{{.Status}}'`)

---

### T2 — Migrate n8n vault-token-header to AppRole (~45 min, REMOTE)

**Realm**: work.

**Build**:
- Enable AppRole on Vault if not already: `vault auth enable approle`
- Create role `n8n-services` with scoped policy (read on `secret/data/anthropic`, `secret/data/postgres-roles`, etc — list per current Vault audit)
- Generate role-id + secret-id pair
- Update n8n credential `0wPA4DCDuehPC9Mf` via API:
  - Switch type from header-with-static-token to a Code node that does AppRole login → caches token → injects on every Vault call
  - OR (simpler) replace the header credential with a fresh AppRole-issued token, accept that token rotates every TTL window (typically 1h) — write a renewer cron
- Confirm at least 3 n8n workflows that hit Vault still succeed after the swap

**Acceptance**:
- `docker exec homeai-vault vault token lookup -accessor <root-accessor>` shows the root token is no longer being used by n8n
- A spot-check workflow run completes without secret-fetch errors

---

### T3 — Revoke + delete the long-lived root token (~20 min, REMOTE)

**Realm**: owner.

**Build**:
- Generate a fresh root token using the unseal keys (`vault operator generate-root`) for break-glass use; store the new root token in Restic-backed encrypted file (NOT in Vault itself)
- Revoke the old long-lived root token: `vault token revoke <old-token>`
- Update bootstrap docs to reflect the new pattern

**Acceptance**:
- Old root token (the one previously in n8n) returns 403 on `vault token lookup`
- Break-glass token works for a test `vault read secret/data/postgres-roles` call

---

## What this sprint does NOT do

- Does not rotate every secret in Vault (only the root token and the n8n credential)
- Does not refactor bot-responder's Vault access pattern (that's already using a scoped service token per [[project_homeai]])
- Does not migrate to a HashiCorp Vault Enterprise feature

## Follow-on sprints

- **U??? — start.sh `--profile phase2`** (also on TECH-DEBT.md): once auto-unseal is stable, add a profile flag that issues short-lived `VAULT_SERVICES_TOKEN` for Phase 2 services (garmin, etc.) instead of long-lived ones
- **U??? — periodic AppRole secret-id rotation**: cron job that rotates secret-ids every 30 days; logs to `cognition.audit_log` (if exists) or `system_state`
