/**
 * Wix Velo backend module — paste into:
 *   Wix Studio → Code → Backend → new file `homeai-handoff.web.js`
 *
 * Before this works:
 *   1. Add Wix secret `homeai_hmac` (Secrets Manager) — same value as
 *      Vercel env WIX_HMAC_SECRET on the Next.js side.
 *   2. Update TARGET to the actual hosted dashboard URL.
 *   3. Either tag Wix Members with badges (homeai-owner / homeai-manager /
 *      homeai-accountant) OR set a custom contact field `homeai_role`.
 */

import { webMethod, Permissions } from 'wix-web-module';
import { currentMember } from 'wix-members-backend';
import { getSecret } from 'wix-secrets-backend';
import { createHmac } from 'crypto';

const TARGET = 'https://homeai.malthousetintagel.com';
const TOKEN_TTL_SECONDS = 60;

export const buildHandoffUrl = webMethod(
  Permissions.SiteMember,
  async () => {
    const member = await currentMember.getMember();
    if (!member) throw new Error('not signed in');

    const role = await mapMemberToRole(member);
    if (!role) throw new Error('no Home AI role assigned to this member');

    const secret = await getSecret('homeai_hmac');
    const exp = Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS;
    const token = Buffer.from(JSON.stringify({
      sub: member._id,
      role,
      email: member.loginEmail,
    })).toString('base64url');
    const sig = createHmac('sha256', secret)
                  .update(`${token}.${exp}`)
                  .digest('hex');
    return `${TARGET}/?wix_token=${token}&exp=${exp}&sig=${sig}`;
  }
);

async function mapMemberToRole(member) {
  // (A) Custom contact field
  const fields = member?.contactDetails?.customFields ?? {};
  if (fields.homeai_role?.value) return fields.homeai_role.value;

  // (B) Badge-based — uncomment and replace badge IDs as needed
  // if (member.badges?.includes('homeai-owner')) return 'owner';
  // if (member.badges?.includes('homeai-manager')) return 'manager';
  // if (member.badges?.includes('homeai-accountant')) return 'accountant';

  // (C) Hard-coded for first cut — Jo's own login goes here
  if (member.loginEmail === 'jolyon.sandercock@gmail.com') return 'owner';

  return null;
}
