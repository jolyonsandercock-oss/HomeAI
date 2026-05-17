import { NextRequest, NextResponse } from 'next/server';
import { runSlug } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
export const maxDuration = 30;

export async function GET(req: NextRequest, { params }: { params: { slug: string } }) {
  try {
    const url = new URL(req.url);
    const obj: Record<string, unknown> = {};
    url.searchParams.forEach((v, k) => { obj[k] = v; });
    const rows = await runSlug(params.slug, obj);
    return NextResponse.json(rows);
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}
