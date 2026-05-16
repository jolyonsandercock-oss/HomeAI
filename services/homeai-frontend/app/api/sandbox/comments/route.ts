import { NextRequest, NextResponse } from 'next/server';
import { pool } from '@/lib/db';

export const dynamic = 'force-dynamic';

export async function GET(req: NextRequest) {
  const cid = new URL(req.url).searchParams.get('component_id');
  const page = new URL(req.url).searchParams.get('page_path');
  const where: string[] = [];
  const args: (string | null)[] = [];
  if (cid)  { args.push(cid);  where.push(`component_id = $${args.length}`); }
  if (page) { args.push(page); where.push(`page_path = $${args.length}`); }
  const sql = `SELECT id, component_id, comment_text, author, page_path, created_at, resolved_at FROM sandbox_comments ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY created_at DESC LIMIT 100`;
  const r = await pool().query(sql, args);
  return NextResponse.json(r.rows);
}

export async function POST(req: NextRequest) {
  const body = await req.json();
  const { component_id, comment_text, page_path, author } = body || {};
  if (!component_id || !comment_text) {
    return NextResponse.json({ error: 'component_id + comment_text required' }, { status: 400 });
  }
  const r = await pool().query(
    `INSERT INTO sandbox_comments (component_id, comment_text, author, page_path)
     VALUES ($1, $2, $3, $4) RETURNING id, created_at`,
    [component_id, comment_text, author ?? null, page_path ?? null]
  );
  return NextResponse.json(r.rows[0]);
}
