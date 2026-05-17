import { NextResponse } from 'next/server';
import { healthCheck } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
export const maxDuration = 30;  // Tailscale Funnel cold-relay can take 5-15s

export async function GET() {
  try {
    return NextResponse.json(await healthCheck());
  } catch (e) {
    return NextResponse.json({ status: 'degraded', error: (e as Error).message }, { status: 503 });
  }
}
