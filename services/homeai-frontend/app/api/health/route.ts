import { NextResponse } from 'next/server';
import { healthCheck } from '@/lib/db';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    return NextResponse.json(await healthCheck());
  } catch (e) {
    return NextResponse.json({ status: 'degraded', error: (e as Error).message }, { status: 503 });
  }
}
