import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from "next/server";
import { pool } from "@/lib/db";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

interface Body {
  task_id: number;
  status: "done" | "dismissed" | "snoozed";
  notes?: string;
  create_ignore_rule?: boolean;
}

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  let body: Body;
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: "invalid JSON" }, { status: 400 }); }

  if (!body.task_id || !body.status) {
    return NextResponse.json({ error: "task_id and status required" }, { status: 400 });
  }

  if (!["done", "dismissed", "snoozed"].includes(body.status)) {
    return NextResponse.json({ error: "status must be done, dismissed, or snoozed" }, { status: 400 });
  }

  const p = pool();
  const client = await p.connect();
  try {
    await client.query("SELECT home_ai.set_realm('owner')");

    const result = await client.query(
      `SELECT home_ai.update_email_task_status($1, $2, $3) as task_id`,
      [body.task_id, body.status, body.notes || null]
    );

    // If requested, create an ignore rule for this sender's domain
    if (body.create_ignore_rule && body.status === 'dismissed') {
      try {
        const taskResult = await client.query(
          "SELECT e.from_address FROM email_tasks et JOIN emails e ON e.id = et.email_id WHERE et.id = $1",
          [body.task_id]
        );
        const fromAddr = taskResult.rows[0]?.from_address || "";
        const domain = fromAddr.split("@")[1]?.replace(/[>]$/g, "");
        if (domain) {
          await client.query(
            "SELECT home_ai.insert_email_ignore_rule($1, $2)",
            [domain, "\comm"]
          );
        }
      } catch {
        // Non-critical — ignore rule creation failure should not block status update
      }
    }

    return NextResponse.json({ ok: true, id: result.rows[0]?.task_id });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  } finally {
    client.release();
  }
}
