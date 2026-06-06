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
  let invoiceId: string;
  try {
    const body = await req.json();
    invoiceId = body.invoice_id;
  } catch {
    return NextResponse.json({ error: "invalid JSON" }, { status: 400 });
  }

  if (!invoiceId) {
    return NextResponse.json({ error: "invoice_id required" }, { status: 400 });
  }

  const p = pool();
  const client = await p.connect();
  try {
    const result = await client.query(
      "SELECT home_ai.flag_invoice_re_extract($1)",
      [invoiceId]
    );

    return NextResponse.json({
      ok: true,
      message: "Invoice flagged for re-extraction. Next Haiku fallback run will process it."
    });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  } finally {
    client.release();
  }
}
