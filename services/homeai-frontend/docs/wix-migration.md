# Wix migration plan — host the Next.js dashboard for access-controlled third-party use

## Why Wix at all

Two reasons:

1. **You already pay for Wix Studio**, and it owns the public-facing brand (`malthousetintagel.com`). Hosting the dashboard at `app.malthousetintagel.com` keeps the access path inside one brand surface staff and managers already trust.
2. **Wix has a working member-area + role system out of the box** (Wix Members + Velo `wix-members-backend`). We avoid building our own SSO from scratch for non-Jo viewers (manager, accountant, partner).

What Wix is *not* for: hosting the Next.js compute. Wix Studio doesn't host arbitrary Node.js server code. The Next.js app stays on Vercel (or our Docker `homeai-frontend` behind Tailscale Funnel) — Wix sits in front as the auth gate + branded entry.

## The architecture — three layers

```
   ┌──────────────────────┐    ┌──────────────────────┐    ┌──────────────────────┐
   │  Wix Studio site     │    │  Velo backend (web   │    │  homeai-frontend     │
   │  (public, branded)   │ ─→ │  module on Wix)      │ ─→ │  Vercel or Docker    │
   │                      │    │                      │    │                      │
   │  member login        │    │  validates session,  │    │  serves the app,     │
   │  iframe / link out   │    │  mints short-lived   │    │  validates HMAC      │
   │                      │    │  HMAC-signed URL     │    │  query token         │
   └──────────────────────┘    └──────────────────────┘    └──────────────────────┘
                                                                    │
                                                                    ↓
                                                        ┌──────────────────────┐
                                                        │  homeai_readonly     │
                                                        │  Postgres (Tailscale │
                                                        │  Funnel, IP-pinned)  │
                                                        └──────────────────────┘
```

**Why not just `iframe src="https://homeai-frontend.vercel.app"` with no auth in the middle?**
Because the iframe leaks: anyone who shares the URL bypasses the Wix login. The HMAC token closes that.

## The HMAC handoff in detail

Issued by Velo, validated by Next.js middleware:

```
GET /?wix_token=eyJ1...&exp=1716000000&sig=HMAC_SHA256(wix_token + exp, SHARED_SECRET)
```

- `wix_token` — opaque, contains the Wix member's role (`owner`, `manager`, `accountant`)
- `exp` — unix seconds, max 5 minutes in the future
- `sig` — HMAC-SHA256 over `wix_token + exp` using a secret known to both Velo (env var) and Next.js (Vault → Vercel env)

Next.js middleware:
1. Parses `wix_token`, `exp`, `sig`
2. Re-computes HMAC, must match
3. Rejects if `exp` past
4. Sets a `homeai-session` HttpOnly cookie scoped to the role for 60 minutes
5. Subsequent requests check cookie; no `wix_token` shown in browser history

The HMAC secret is in Vault at `secret/wix/hmac_secret`. Velo reads it once at deploy via the Wix Secrets Manager (paste it in). Vercel reads it from `WIX_HMAC_SECRET` env (set via `vercel env add`).

## Member roles → page visibility

Single source of truth in `app/middleware.ts`:

```ts
const ROLES = {
  owner:      ['*'],
  manager:    ['/', '/sales', '/rooms', '/restaurant', '/bar', '/cafe', '/staff', '/tasks', '/comms'],
  accountant: ['/sales', '/admin'],
  partner:    ['/'],
};
```

Anything outside the role's whitelist redirects to `/`.

## Proof-of-concept Velo page

This is the code Jo pastes into Wix Studio → Velo Code → Backend → `homeai-handoff.web.js`. Plus the frontend snippet that wires the button.

### Backend (Velo `homeai-handoff.web.js`)

```javascript
import { webMethod, Permissions } from 'wix-web-module';
import { currentMember } from 'wix-members-backend';
import { getSecret } from 'wix-secrets-backend';
import { createHmac } from 'crypto';

const TARGET = 'https://homeai.malthousetintagel.com';  // Vercel/Tailscale Funnel URL

export const buildHandoffUrl = webMethod(
  Permissions.SiteMember,        // only signed-in members
  async () => {
    const member = await currentMember.getMember();
    if (!member) throw new Error('not signed in');

    // Look up the role — Wix Members has badges/roles or you store it in
    // a custom 'role' field on the member profile.
    const role = await mapMemberToRole(member);
    if (!role) throw new Error('member has no Home AI role');

    const secret = await getSecret('homeai_hmac');
    const exp = Math.floor(Date.now() / 1000) + 60;       // 60-second window
    const token = Buffer.from(JSON.stringify({
      sub: member._id, role, email: member.loginEmail,
    })).toString('base64url');
    const sig = createHmac('sha256', secret)
                  .update(`${token}.${exp}`)
                  .digest('hex');
    return `${TARGET}/?wix_token=${token}&exp=${exp}&sig=${sig}`;
  }
);

async function mapMemberToRole(member) {
  // Implementation A — read a custom field 'homeai_role' on the member profile
  if (member.contactDetails && member.contactDetails.customFields) {
    const f = member.contactDetails.customFields.homeai_role;
    if (f && f.value) return f.value;
  }
  // Implementation B — by Wix badge
  if (member.badges && member.badges.includes('homeai-owner')) return 'owner';
  if (member.badges && member.badges.includes('homeai-manager')) return 'manager';
  if (member.badges && member.badges.includes('homeai-accountant')) return 'accountant';
  return null;
}
```

### Frontend (Velo page code on the "Operations" Wix page)

```javascript
import { buildHandoffUrl } from 'backend/homeai-handoff.web';

$w.onReady(() => {
  $w('#openDashboardBtn').onClick(async () => {
    try {
      const url = await buildHandoffUrl();
      // Either open in the embedded iframe, or window.location.href
      if ($w('#dashboardFrame')) {
        $w('#dashboardFrame').src = url;
      } else {
        window.location.href = url;
      }
    } catch (e) {
      $w('#statusText').text = 'Access denied: ' + e.message;
    }
  });
});
```

### Next.js middleware (drop into `app/middleware.ts`)

```ts
import { NextResponse, NextRequest } from 'next/server';
import { createHmac } from 'crypto';

const SECRET = process.env.WIX_HMAC_SECRET;
const COOKIE = 'homeai-session';

const ROLES: Record<string, string[]> = {
  owner:      ['*'],
  manager:    ['/', '/sales', '/rooms', '/restaurant', '/bar', '/cafe', '/staff', '/tasks', '/comms'],
  accountant: ['/sales', '/admin'],
  partner:    ['/'],
};

function allowed(role: string, path: string): boolean {
  const list = ROLES[role] || [];
  return list.includes('*') || list.some(p => path === p || path.startsWith(p + '/'));
}

export function middleware(req: NextRequest) {
  // 1. Try Wix handoff
  const url = req.nextUrl;
  const token = url.searchParams.get('wix_token');
  const exp   = url.searchParams.get('exp');
  const sig   = url.searchParams.get('sig');
  if (token && exp && sig && SECRET) {
    const computed = createHmac('sha256', SECRET).update(`${token}.${exp}`).digest('hex');
    if (computed === sig && Number(exp) * 1000 > Date.now()) {
      const payload = JSON.parse(Buffer.from(token, 'base64url').toString());
      // Strip handoff params from URL
      url.searchParams.delete('wix_token');
      url.searchParams.delete('exp');
      url.searchParams.delete('sig');
      const res = NextResponse.redirect(url);
      res.cookies.set(COOKIE, JSON.stringify({ role: payload.role, exp: Date.now() + 3600_000 }), {
        httpOnly: true, sameSite: 'lax', secure: true, maxAge: 3600,
      });
      return res;
    }
  }

  // 2. Existing session
  const cookie = req.cookies.get(COOKIE)?.value;
  if (cookie) {
    try {
      const { role, exp } = JSON.parse(cookie);
      if (exp > Date.now() && allowed(role, url.pathname)) {
        return NextResponse.next();
      }
    } catch {}
  }

  // 3. Bounce to Wix sign-in
  return NextResponse.redirect('https://malthousetintagel.com/operations');
}

export const config = { matcher: '/((?!api/health|_next|favicon).*)' };
```

## Monitoring + audit

Every successful handoff writes a row to `wix_handoff_audit`:

```sql
CREATE TABLE wix_handoff_audit (
  id            BIGSERIAL PRIMARY KEY,
  wix_member_id TEXT,
  role          TEXT,
  email         TEXT,
  ip            INET,
  user_agent    TEXT,
  pages_visited JSONB,
  expired_at    TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`POST /api/wix-handoff/log` writes that row at the moment of HMAC validation. Surfaced on `/backend` page in the dashboard so Jo can see exactly who's looked at what.

## Step-by-step deploy

| # | Step | Who |
|---|---|---|
| 1 | Generate HMAC secret: `openssl rand -hex 32` | local |
| 2 | Store in Vault: `vault kv put secret/wix hmac_secret=…` | local |
| 3 | Add Vercel env: `vercel env add WIX_HMAC_SECRET production` | local |
| 4 | Wix Studio → Secrets Manager → add `homeai_hmac` with the same value | Jo, Wix dashboard |
| 5 | Wix Velo → Backend → paste `homeai-handoff.web.js` above | Jo |
| 6 | Wix Studio → new page `/operations` with `openDashboardBtn` + `dashboardFrame` iframe | Jo |
| 7 | Drop `app/middleware.ts` into the Next.js repo + `vercel --prod` | local |
| 8 | First-test: sign in as Jo (owner badge) → click button → see dashboard | Jo |

## Risks + open questions

- **iframe-busting** — Wix iframe sits inside their CSP; Vercel's default `X-Frame-Options: DENY` will block it. Need to allow `frame-ancestors: malthousetintagel.com` on Next.js responses (already accounted for in vercel.json once we add `headers` section).
- **Mobile** — Wix mobile shells iframes oddly. Bottom tab nav on the Next.js app may collide with Wix's own header. Test on iOS Safari + Android Chrome.
- **Member role updates** — Wix Members API returns whatever roles Jo set up; we can change role mapping anytime in `mapMemberToRole`. But role changes only apply on next handoff, not mid-session.

## What goes in U+ as follow-up

- Wix Members → automatic provisioning when a new role is needed (currently manual)
- Audit dashboard widget on `/backend` showing recent Wix handoffs
- Cookie rotation: HMAC handoff every hour rather than relying on 60-min cookie alone
- IP allowlist via Tailscale Funnel for the Postgres connection
