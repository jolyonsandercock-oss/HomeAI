# U57 — Realm R3 + R4 (Auth + App split) + open in-person bundle

**Prereqs**: U52 / U53 / U55 / U56 shipped (realm R1+R2+R5+R6 done; R7 done; REALM_ENFORCE middleware shipped dormant on build-dashboard).

**Realm**: cross-cutting. R3 + R4 are the final realm phases that move enforcement from dormant to live.

**Remote vs in-person**: ~90% in-person. Needs Jo at the box for `tailscale cert <fqdn>` (sudo + tailnet identity) and for the Authelia/Caddy reload sequence. Build-side prep (~30 min remote) is done in U54-D's wake; the in-person sit is ~90–120 min.

**Why this sprint exists**: U52 shipped the `REALM_ENFORCE` env var dormant. To flip it on, build-dashboard and bot-responder need to receive a trustworthy `X-Realm` header on every request. That header gets injected by Caddy after Authelia confirms identity via forward_auth — and Authelia's session cookie domain has to match an actual FQDN, not a Tailscale IP, before browsers will honour the cookie cycle ([[feedback_authelia_cookie_domain]]). The whole thing pivots on one `tailscale cert` command that mints the FQDN-bound cert.

**Discipline carry-overs**:
- Rule #1 — verify before done. After the flip, hit `/api/snapshot` with each of X-Realm: owner/work/family and confirm the response shapes differ (work shouldn't see family vehicles; family shouldn't see touchoffice).
- Rule #8 — scripts with prompts beat copy-paste. The whole flow lands in `scripts/u57-r3-r4-flip.sh` so Jo runs `bash …` and answers prompts rather than typing tailscale-cert flags from memory.
- Rule #9 — break iteration after 3 attempts. If Authelia forward_auth refuses to round-trip after 3 attempts: revert Caddyfile + REALM_ENFORCE=0 + leave a debt entry; don't iterate fog.

## Tracks

### T1 — Tailscale FQDN cert (~15 min, Jo at box)

**Realm**: owner.

**Jo runs**:
```bash
sudo tailscale cert jolybox.<tailnet>.ts.net
# (Jo's tailnet name is the .ts.net domain shown in `tailscale status --self`)
```

**Outputs**: `jolybox.<tailnet>.ts.net.crt` + `.key` in cwd. The `scripts/u57-r3-r4-flip.sh` script will offer to move them to `/etc/caddy/tls/` and chmod 600.

**Acceptance**: `openssl x509 -in jolybox.<tailnet>.ts.net.crt -text` shows the FQDN as CN; `tailscale status --self --json | jq .Self.DNSName` matches.

---

### T2 — Caddy forward_auth wiring (~30 min, mostly remote prep)

**Realm**: owner.

**Build (pre-flight, can land before T1)**:
- Edit `config/caddy/Caddyfile`:
  - Add `tls /etc/caddy/tls/jolybox.<tailnet>.ts.net.crt /etc/caddy/tls/jolybox.<tailnet>.ts.net.key`
  - For `/dashboard*`, `/metabase*`, `/auth/*`:
    - `forward_auth homeai-authelia:9091 { uri /api/verify?rd=https://{host}/auth/ copy_headers Remote-User Remote-Groups }`
  - For `/dashboard*` specifically: after forward_auth, add `header_up X-Realm {http.auth.user.groups}` so the realm flows through to build-dashboard.
- Edit `security/authelia-v2/configuration.yml`:
  - Set `session.cookies[].domain` to the FQDN (currently a Tailscale IP).
  - Add `access_control.rules` mapping users to realms (Jo → owner; future info@/admin@ → work; etc).
- Update `users_database.yml` group memberships: `jo: [admins, owner]` (or however the realm group is encoded; verify with Authelia's group→header mapping).

**Acceptance**:
- `docker compose config | grep -A2 caddy` shows the new mounts.
- `docker compose restart caddy authelia` + `curl -sv -H 'Host: jolybox.<tailnet>.ts.net' https://localhost/dashboard/api/healthz` returns 302 → /auth/ when not logged in, 200 when authenticated.

---

### T3 — Flip REALM_ENFORCE=1 on build-dashboard + bot-responder (~10 min)

**Realm**: cross-cutting.

**Build**:
- `docker-compose.yml`: change `REALM_ENFORCE: "0"` → `REALM_ENFORCE: "1"` on build-dashboard.
- Add the same env to bot-responder (today bot-responder reads sender_realm from `bot_sender_whitelist` directly — REALM_ENFORCE there is a belt-and-braces flag for any future HTTP-fronted entry point).
- Rebuild + restart per [[feedback_dashboard_image_rebuild]] (harvest POSTGRES_PASSWORD from Vault).

**Acceptance**:
- `curl -H 'X-Realm: work' https://jolybox.<tailnet>.ts.net/dashboard/api/snapshot` returns 200 with pub-side data only.
- `curl -H 'X-Realm: family' https://jolybox.<tailnet>.ts.net/dashboard/api/snapshot` returns 200 with the family-side view (no touchoffice).
- `curl https://jolybox.<tailnet>.ts.net/dashboard/api/snapshot` (no header, no auth) returns 302 → /auth/.

---

### T4 — Install ~/.claude PreToolUse hooks (~2 min)

**Realm**: n/a (dev tooling).

**Jo runs**:
```bash
bash /home_ai/.claude/scripts/u13-install-hooks.sh
```
Installer backs up `~/.claude/settings.json`, jq-merges the hook entries from `.claude/hooks/`, runs negative tests, prints PASS/FAIL.

**Acceptance**:
- `jq '.hooks.PreToolUse' ~/.claude/settings.json` returns non-empty.

---

### T5 — Drain the Authelia/Vault cosmetic config drift (~20 min)

**Realm**: owner.

**Build**:
- Re-run `scripts/authelia-bootstrap.sh` answering Y at the "Import existing into Vault?" prompts so secrets in `security/authelia-v2/configuration.yml` match `secret/authelia` in Vault.
- `docker compose restart authelia` + `vault kv get secret/authelia` cross-check.

**Acceptance**:
- `vault kv get -field=jwt_secret secret/authelia` matches the value in `configuration.yml`.

## Sequence + acceptance

| # | Track | Effort | Where |
|---|-------|--------|-------|
| 1 | Tailscale FQDN cert    | 15m  | Jo at box |
| 2 | Caddy forward_auth wiring | 30m  | mostly remote prep + Jo restart |
| 3 | REALM_ENFORCE flip     | 10m  | Jo runs rebuild |
| 4 | Hook install           | 2m   | Jo runs script |
| 5 | Authelia/Vault drift   | 20m  | Jo runs script + restart |

**Total**: ~75 min wall-clock when paths go straight. ~120 min if forward_auth needs a second attempt.

## What this sprint does NOT do

- Phase 2 ramps (Companies House key, Land Registry data, HMRC sandbox).
  Those are separate Jo-at-keyboard touches — bundle separately so the
  realm session isn't held up by a missing API key.
- Switch AI workers from postgres-superuser to homeai_pipeline. That's
  R6 enforcement-active, queued separately (see debt.yaml).
- Touch P3 Xero (external blocker).
- NAS off-host backup (postponed by Jo).

## Abort criteria

Per discipline rule #9:
- Forward_auth refuses to round-trip after 3 attempts → revert Caddyfile, leave REALM_ENFORCE=0, document the failure mode, hand to fresh session.
- Authelia cookie not honoured by browser after the cert+domain change → check `tailscale status` confirms the FQDN is bound, check Caddy is actually serving over that FQDN (not the IP). If both correct, file a Tailscale support ticket and revert.
