import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from 'next/server';
import { insertSafeMovement } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
 NextRequest) {
  const body = await req.json();
  if (!body?.movement_date || !body?.site || !body?.direction || !body?.amount_pence) {
    return NextResponse.json({ error: 'movement_date + site + direction + amount_pence required' }, { status: 400 });
  }
  try {
    return NextResponse.json(await insertSafeMovement(body));
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
