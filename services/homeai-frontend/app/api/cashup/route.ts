import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from 'next/server';
import { upsertCashupInput } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
 NextRequest) {
  const body = await req.json();
  if (!body?.site || !body?.cashup_date || !body?.till_id) {
    return NextResponse.json({ error: 'site + cashup_date + till_id required' }, { status: 400 });
  }
  try {
    return NextResponse.json(await upsertCashupInput(body));
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
