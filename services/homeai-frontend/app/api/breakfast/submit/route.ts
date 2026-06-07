import { NextRequest, NextResponse } from 'next/server';
import { pool, withRealm } from '@/lib/db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
export const maxDuration = 30;

// GET: validate token, return order status
export async function GET(req: NextRequest) {
  try {
    const url = new URL(req.url);
    const token = url.searchParams.get('token');
    if (!token) {
      return NextResponse.json({ valid: false, error: 'Missing token' }, { status: 400 });
    }

    // Guest-facing token endpoint — accommodation data is the 'work' realm.
    return await withRealm('work', async (client) => {
      // Check token exists and service_date hasn't passed
      const sendResult = await client.query(
        `SELECT bes.accommodation_booking_id, bes.service_date, bes.guest_count,
                ab.guest_name, ab.room
         FROM breakfast_email_sends bes
         JOIN accommodation_bookings ab ON ab.id = bes.accommodation_booking_id
         WHERE bes.email_token = $1`,
        [token]
      );

      if (sendResult.rowCount === 0) {
        return NextResponse.json({ valid: false, error: 'Invalid or expired booking token.' });
      }

      const send = sendResult.rows[0];

      // Check if already ordered
      const orderResult = await client.query(
        `SELECT guest_index, hot_drink, dish, allergies, notes
         FROM breakfast_orders
         WHERE email_token = $1 AND service_date = $2
         ORDER BY guest_index
         LIMIT 1`,
        [token, send.service_date]
      );

      const already_ordered = orderResult.rowCount ?? 0 > 0;
      const existing_order = already_ordered ? orderResult.rows[0] : undefined;

      return NextResponse.json({
        valid: true,
        guest_name: send.guest_name,
        room: send.room,
        guest_count: send.guest_count,
        service_date: send.service_date,
        already_ordered,
        existing_order: existing_order || undefined,
      });
    }, { entity: '1' });
  } catch (e) {
    return NextResponse.json({ valid: false, error: (e as Error).message }, { status: 500 });
  }
}

// POST: submit breakfast order
export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const { token, guest_index, hot_drink, dish, allergies, notes } = body;

    if (!token || !dish) {
      return NextResponse.json({ ok: false, message: 'Token and dish are required.' }, { status: 400 });
    }

    const guestIdx = guest_index || 1;

    const p = pool();
    const client = await p.connect();
    try {
      await client.query('BEGIN');
      // Realm/entity must be set inside this transaction so the writes below
      // run with realm context (accommodation = 'work' realm, entity 1).
      await client.query("SELECT home_ai.set_realm('work')");
      await client.query("SELECT set_config('app.current_entity', '1', true)");

      // Validate token and get booking details
      const sendResult = await client.query(
        `SELECT bes.accommodation_booking_id, bes.service_date, bes.guest_count
         FROM breakfast_email_sends bes
         WHERE bes.email_token = $1
         FOR UPDATE`,
        [token]
      );

      if (sendResult.rowCount === 0) {
        await client.query('ROLLBACK');
        return NextResponse.json({ ok: false, message: 'Invalid or expired booking token.' }, { status: 400 });
      }

      const send = sendResult.rows[0];

      // Check service date hasn't passed (can still order for today before 6am)
      // Allow ordering up to the service date
      const today = new Date().toISOString().slice(0, 10);
      if (send.service_date < today) {
        await client.query('ROLLBACK');
        return NextResponse.json({ ok: false, message: 'This breakfast date has already passed.' }, { status: 400 });
      }

      // Get submitter IP
      const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
                 req.headers.get('x-real-ip') ||
                 '127.0.0.1';

      // Upsert breakfast order
      await client.query(
        `INSERT INTO breakfast_orders
           (accommodation_booking_id, email_token, guest_index, service_date,
            hot_drink, dish, allergies, notes, submitter_ip, realm)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::inet, 'work')
         ON CONFLICT (email_token, guest_index)
         DO UPDATE SET
           hot_drink = EXCLUDED.hot_drink,
           dish = EXCLUDED.dish,
           allergies = EXCLUDED.allergies,
           notes = EXCLUDED.notes,
           submitted_at = NOW(),
           submitter_ip = EXCLUDED.submitter_ip`,
        [
          send.accommodation_booking_id,
          token,
          guestIdx,
          send.service_date,
          hot_drink || null,
          dish,
          allergies || null,
          notes || null,
          ip,
        ]
      );

      // Update responded_at on the send
      await client.query(
        `UPDATE breakfast_email_sends
         SET responded_at = NOW()
         WHERE email_token = $1 AND responded_at IS NULL`,
        [token]
      );

      await client.query('COMMIT');

      return NextResponse.json({
        ok: true,
        message: `Your breakfast order for ${send.service_date} has been received. Enjoy your stay!`,
      });
    } catch (e) {
      try { await client.query('ROLLBACK'); } catch { /* ignore */ }
      return NextResponse.json({ ok: false, message: (e as Error).message }, { status: 500 });
    } finally {
      client.release();
    }
  } catch (e) {
    return NextResponse.json({ ok: false, message: (e as Error).message }, { status: 500 });
  }
}
