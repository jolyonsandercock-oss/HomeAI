import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from "next/server";
import { pool } from "@/lib/db";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  let body: any;
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: "invalid JSON" }, { status: 400 }); }

  if (!body.title?.trim()) {
    return NextResponse.json({ error: "title required" }, { status: 400 });
  }

  const p = pool();
  const client = await p.connect();
  try {
    const result = await client.query(
      "SELECT home_ai.insert_snag($1, $2, $3, $4, $5, $6, $7)",
      [
        body.title.trim(),
        body.description || null,
        body.image_path || null,
        body.category || "ux",
        body.priority || 3,
        body.submitted_by || null,
        body.source || "api"
      ]
    );
    return NextResponse.json({ ok: true, id: result.rows[0]?.insert_snag });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  } finally {
    client.release();
  }
}
