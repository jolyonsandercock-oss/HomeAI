import { NextResponse } from 'next/server';
import { pool } from '@/lib/db';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const r = await pool().query('SELECT NOW() AS now');
    return NextResponse.json({ status: 'ok', db_time: r.rows[0].now });
  } catch (e) {
    return NextResponse.json({ status: 'degraded', error: (e as Error).message }, { status: 503 });
  }
}
