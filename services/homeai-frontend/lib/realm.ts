import { NextRequest } from 'next/server';

export type Realm = 'owner' | 'work' | 'personal';

// Authelia group vocabulary → DB realm. Mirrors build-dashboard _UI_TO_DB_REALM.
// Only realm-named groups are mapped (role groups like admin/manager/staff are
// ignored — every user also carries an explicit realm group: jo→owner,
// karl→work, staff→work).
const GROUP_TO_REALM: Record<string, Realm> = {
  owner: 'owner',
  all: 'owner',
  work: 'work',
  personal: 'personal',
  family: 'personal', // U139 alias
};

// Precedence so the order of groups in the header doesn't matter.
const PRECEDENCE: Realm[] = ['owner', 'personal', 'work'];

/**
 * Derive the request realm from the TRUSTED Authelia forward_auth identity.
 * Caddy copies `Remote-Groups` from Authelia's /api/verify response onto the
 * upstream request (FQDN path only). We never trust a client-supplied realm.
 *
 * Defaults to 'work' (least-privileged useful realm) when no/unknown identity,
 * so owner/personal data is NEVER served without an authenticated owner/
 * personal session. On the IP-backdoor route there is no forward_auth, so the
 * header is absent → 'work'. (Hardening follow-up: strip client Remote-* /
 * remove the IP backdoor so the header can't be spoofed off-tailnet.)
 */
export function realmFromRequest(req: NextRequest): Realm {
  const groups = (req.headers.get('remote-groups') || '')
    .split(',')
    .map((g) => g.trim().toLowerCase())
    .filter(Boolean);
  const realms = new Set(
    groups.map((g) => GROUP_TO_REALM[g]).filter(Boolean) as Realm[],
  );
  for (const r of PRECEDENCE) if (realms.has(r)) return r;
  return 'work';
}
