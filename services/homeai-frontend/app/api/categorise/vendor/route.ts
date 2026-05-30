import { NextRequest, NextResponse } from "next/server";
import { pool } from "@/lib/db";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

interface Body {
  domain_pattern: string;
  category: string;
  site: string;
  vendor_display?: string;
}

export async function POST(req: NextRequest) {
  let body: Body;
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: "invalid JSON" }, { status: 400 }); }

  if (!body.domain_pattern) {
    return NextResponse.json({ error: "domain_pattern required" }, { status: 400 });
  }

  const p = pool();
  const client = await p.connect();
  try {
    await client.query("SELECT home_ai.set_realm('owner')");

    const result = await client.query(
      `SELECT rule_id FROM home_ai.upsert_vendor_rule($1, $2, $3, $4)`,
      [
        body.domain_pattern.toLowerCase().trim(),
        body.category || null,
        body.vendor_display || body.domain_pattern,
        body.site || "shared",
      ]
    );

    return NextResponse.json({ ok: true, rule_id: result.rows[0]?.rule_id });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  } finally {
    client.release();
  }
}
