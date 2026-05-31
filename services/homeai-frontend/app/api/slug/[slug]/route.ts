import { NextRequest, NextResponse } from 'next/server';
import { runSlug } from '@/lib/db';
import { realmFromRequest } from '@/lib/realm';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
export const maxDuration = 30;

export async function GET(req: NextRequest, { params }: { params: { slug: string } }) {
  try {
    const url = new URL(req.url);
    const obj: Record<string, unknown> = {};
    url.searchParams.forEach((v, k) => { obj[k] = v; });
    // Realm gate: derive from the trusted Authelia identity (Remote-Groups),
    // never from client input. owner→all, work/personal scoped by RLS.
    const realm = realmFromRequest(req);
    const rows = await runSlug(params.slug, obj, realm);
    return NextResponse.json(rows);
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
