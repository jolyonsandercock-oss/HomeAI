# U153 — Multi-user readiness: per-staff identity + audit + RBAC

**Prereqs**: U151 (RLS roles applied), U152 (UI surfaces usable).

**Realm**: cross-cutting (security + UX).

**Remote vs in-person**: 100% remote, except Jo needs to provide staff member identity info (name, email, phone) for the first 2-3 accounts.

**Why this sprint exists**: today every UI hit comes in as "Jo" — Authelia has one user, audit_log shows no per-actor distinction, and the role split applies at the connection-pool level (services) not user level (humans). Staff rollout requires: each staff member logs in as themselves; each action is audit-logged with their identity; permissions narrow what they can see/do.

## Tracks

### T1 — Authelia user provisioning (~30 min)

**Build**:
- Define staff roles in Authelia config:
  - `manager` — full work realm access (current pub manager privileges).
  - `floor-staff` — read-only on rota, recon, restaurant; no edits.
  - `kitchen-staff` — recipes, breakfast, stock; not finance.
  - `owner` — Jo, all access (existing).
- Provision 2 test accounts (Jo decides who — likely Helen + a deputy first).
- Document credential issuance flow: Authelia admin → reset password → first-login forces change.

**Acceptance**: 2 test accounts created; each can log in via FQDN.

### T2 — Caddy forward_auth → user identity headers (~30 min)

**Build**: ensure Caddy's `forward_auth homeai-authelia:9091` configuration forwards the right headers to downstream services:
- `Remote-User` → username
- `Remote-Groups` → comma-separated roles
- `Remote-Email`, `Remote-Name`

**Acceptance**: hitting `/api/whoami` (new diagnostic endpoint) returns the current user identity from headers.

### T3 — Audit log enrichment (~60 min)

**Build**:
- Add `actor_user`, `actor_role` columns to `audit_log` (V181).
- Update build-dashboard middleware to capture `Remote-User` + `Remote-Groups` from headers and stash in a ContextVar for the request.
- Every audit_log INSERT in the dashboard gains `actor_user = ctx.user, actor_role = ctx.primary_role`.
- New slug `audit_log_by_actor_7d` for the Admin page.

**Acceptance**: a staff member's actions appear in `audit_log` tagged with their username, not "system".

### T4 — Per-role UI gating (~90 min)

**Build**:
- React middleware: read `Remote-Groups` cookie (set by frontend Authelia integration); decide which nav links / pages to show.
- `/work/finance/*` hidden from `floor-staff` + `kitchen-staff`.
- `/admin/*` hidden from anyone not `owner`.
- A graceful 403 page (not a generic Next.js 404) when a staff member tries to URL-hack into a forbidden page.

**Acceptance**: floor-staff account logs in, sees only `/work/today`, `/work/staff`, `/work/restaurant`. URL-typing `/admin/` shows 403.

### T5 — Action authorization at the API layer (~60 min)

**Build**: every mutation API endpoint checks `Remote-Groups` against an allow-list. Pattern:

```python
@require_role("manager", "owner")
@app.post("/api/recon/note")
async def add_recon_note(...):
    ...
```

UI gating (T4) is convenience; this is the real defence.

**Acceptance**: a floor-staff account POST'ing to `/api/recon/note` gets 403 even though it bypasses UI.

### T6 — Documentation + staff-onboarding doc (~45 min)

**Build**:
- `docs/staff-onboarding.md` — first-time-login walkthrough.
- `docs/runbook-staff.md` — common tasks: how to view rota, file a holiday, escalate a problem.
- Each role's permitted actions table.

**Acceptance**: Jo can hand a new staff member the URL + onboarding doc and they can self-onboard.

## Done criteria

- 2 test accounts working with correct role-scoped access.
- audit_log shows per-actor identity.
- Floor staff can't reach finance or admin even by URL-hacking.
- Onboarding doc covers the happy paths for each role.

## Risk

Medium. RBAC bugs are usually permissive-by-mistake (privilege escalation) rather than restrictive. Mitigations: T5 API-layer authz is the real defence, T4 UI gating is layered convenience. Test matrix per role × per page before declaring done.

## Outcome trigger for U154

Once U153 lands, U154 (dress rehearsal) starts. One real staff member uses the system for a week.
