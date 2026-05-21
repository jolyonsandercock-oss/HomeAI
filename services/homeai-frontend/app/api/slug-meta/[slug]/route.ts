/**
 * U191 — slug metadata endpoint.
 *
 * Returns { slug, empty_state_md, description } for the EmptyState component.
 */
import { NextRequest, NextResponse } from 'next/server';
import { pool } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET(_req: NextRequest, { params }: { params: { slug: string } }) {
  try {
    const { rows } = await pool().query(
      `SELECT slug, display_name, description, empty_state_md
         FROM query_whitelist
        WHERE slug = $1 AND active = true LIMIT 1`,
      [params.slug]
    );
    return NextResponse.json(rows[0] ?? { error: 'not found' }, { status: rows[0] ? 200 : 404 });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  }
}
