import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from 'next/server';
import { getSandboxComments, postSandboxComment } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
export const maxDuration = 30;

export async function GET(req: NextRequest) {
  const cid = new URL(req.url).searchParams.get('component_id') ?? undefined;
  const page = new URL(req.url).searchParams.get('page_path') ?? undefined;
  return NextResponse.json(await getSandboxComments(cid, page));
}

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  const body = await req.json();
  if (!body?.component_id || !body?.comment_text) {
    return NextResponse.json({ error: 'component_id + comment_text required' }, { status: 400 });
  }
  return NextResponse.json(await postSandboxComment(body));
}
