import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from "next/server";
import { withRealm } from "@/lib/db";

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

  if (!body.id || !body.status) {
    return NextResponse.json({ error: "id and status required" }, { status: 400 });
  }

  try {
    // Wrap the SECURITY DEFINER update so its body runs with realm/entity set.
    return await withRealm(realm, async (client) => {
      const result = await client.query(
        "SELECT home_ai.update_snag_status($1, $2, $3, $4)",
        [body.id, body.status, body.notes || null, body.assigned_to || null]
      );
      return NextResponse.json({ ok: true, id: result.rows[0]?.update_snag_status });
    }, { entity: '1' });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  }
}
