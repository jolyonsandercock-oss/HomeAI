import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from 'next/server';
import { verifyPurchase } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
 NextRequest) {
  let body: { purchase_id?: number; action?: string; category?: string };
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: 'invalid JSON' }, { status: 400 }); }

  if (!body.purchase_id || (body.action !== 'confirm' && body.action !== 'categorise')) {
    return NextResponse.json({ error: 'purchase_id + action (confirm|categorise) required' }, { status: 400 });
  }
  if (body.action === 'categorise' && !body.category) {
    return NextResponse.json({ error: 'category required for categorise' }, { status: 400 });
  }
  try {
    return NextResponse.json(await verifyPurchase({
      purchase_id: body.purchase_id, action: body.action, category: body.category,
    }));
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
