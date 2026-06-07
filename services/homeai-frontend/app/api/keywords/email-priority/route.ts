import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from "next/server";
import { withRealm } from "@/lib/db";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

interface Body {
  keyword: string;
  label: string;
}

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  let body: Body;
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: "invalid JSON" }, { status: 400 }); }

  if (!body.keyword) {
    return NextResponse.json({ error: "keyword required" }, { status: 400 });
  }

  try {
    return await withRealm('owner', async (client) => {
      const result = await client.query(
        `SELECT keyword_id FROM home_ai.upsert_email_priority_keyword($1, $2)`,
        [body.keyword.toLowerCase().trim(), body.label || body.keyword]
      );
      return NextResponse.json({ ok: true, id: result.rows[0]?.keyword_id });
    }, { entity: '1' });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  }
}
