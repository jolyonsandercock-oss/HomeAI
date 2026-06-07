import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from 'next/server';
import { withRealm } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

interface FeedbackBody {
  line_id: number;
  corrected_department?: 'bar'|'kitchen'|'rooms'|'cafe'|'overhead'|null;
  corrected_family?: string|null;
  corrected_canonical_id?: number|null;
  corrected_category?: string|null;
  confidence?: number|null;
  corrected_by?: string|null;
}

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  let body: FeedbackBody;
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: 'invalid JSON' }, { status: 400 }); }

  if (!body.line_id || typeof body.line_id !== 'number') {
    return NextResponse.json({ error: 'line_id required (number)' }, { status: 400 });
  }
  const dept = body.corrected_department ?? null;
  if (dept && !['bar','kitchen','rooms','cafe','overhead'].includes(dept)) {
    return NextResponse.json({ error: 'corrected_department invalid' }, { status: 400 });
  }
  if (!dept && !body.corrected_family && !body.corrected_canonical_id && !body.corrected_category) {
    return NextResponse.json({ error: 'at least one correction must be supplied' }, { status: 400 });
  }

  try {
    // withRealm opens a transaction, sets realm (+ entity) LOCAL to it, and
    // keeps every dependent query in that same transaction so the realm does
    // not evaporate before the writes run.
    return await withRealm('owner', async (client) => {
      // Look up vendor_domain + description from the line so the feedback row is
      // self-contained (denormalised for fast pattern queries).
      const lineRows = await client.query(
        `SELECT vil.id, vil.invoice_id, vil.description AS raw_description,
                vii.vendor_domain
           FROM vendor_invoice_lines vil
           JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id
          WHERE vil.id = $1`,
        [body.line_id]
      );
      if (lineRows.rowCount === 0) {
        return NextResponse.json({ error: 'line not found' }, { status: 404 });
      }
      const line = lineRows.rows[0];

      // Insert feedback
      const ins = await client.query(
        `INSERT INTO line_category_feedback
           (line_id, invoice_id, vendor_domain, description_raw,
            corrected_department, corrected_family, corrected_canonical_id,
            corrected_category, source, confidence, corrected_by, realm)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'manual',$9,$10,'shared')
         RETURNING id, corrected_at`,
        [body.line_id, line.invoice_id, line.vendor_domain ?? '',
         line.raw_description ?? '',
         dept, body.corrected_family ?? null, body.corrected_canonical_id ?? null,
         body.corrected_category ?? null,
         body.confidence ?? null,
         body.corrected_by ?? 'jo']
      );

      // Apply correction directly to the line so the UI updates instantly.
      if (dept !== null || body.corrected_family !== undefined || body.corrected_canonical_id !== undefined) {
        const sets: string[] = [];
        const args: unknown[] = [];
        let i = 1;
        if (dept !== null) {
          sets.push(`department = $${i++}`); args.push(dept);
        }
        if (body.corrected_canonical_id !== undefined && body.corrected_canonical_id !== null) {
          sets.push(`canonical_id = $${i++}`); args.push(body.corrected_canonical_id);
        }
        if (body.corrected_family !== undefined && body.corrected_family !== null) {
          sets.push(`suggested_family = $${i++}`); args.push(body.corrected_family);
        }
        if (sets.length > 0) {
          args.push(body.line_id);
          await client.query(
            `UPDATE vendor_invoice_lines SET ${sets.join(', ')} WHERE id = $${i}`,
            args
          );
        }
      }

      return NextResponse.json({
        ok: true,
        feedback_id: ins.rows[0].id,
        corrected_at: ins.rows[0].corrected_at,
      });
    }, { entity: '1' });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  }
}
