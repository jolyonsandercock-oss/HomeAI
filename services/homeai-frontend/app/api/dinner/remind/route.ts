import { NextRequest, NextResponse } from "next/server";
import { withRealm } from "@/lib/db";
import { realmFromRequest } from "@/lib/realm";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";
export const maxDuration = 30;

// DRY_RUN: set to false to actually send emails to real guests
const DRY_RUN = process.env.DINNER_REMIND_DRY_RUN !== "false";

const GF_URL = process.env.GOOGLE_FETCH_URL || "http://google-fetch:8011";

interface RemindBody {
  booking_id: number;
  guest_email: string;
}

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  try {
    const body: RemindBody = await req.json();
    const { booking_id, guest_email } = body;

    if (!booking_id || !guest_email) {
      return NextResponse.json(
        { ok: false, message: "booking_id and guest_email are required" },
        { status: 400 }
      );
    }

    return await withRealm('owner', async (client) => {
      // Look up the guest booking details
      const bookingResult = await client.query(
        `SELECT id, guest_name, checkin_date, checkout_date, room
         FROM accommodation_bookings
         WHERE id = $1`,
        [booking_id]
      );

      if (bookingResult.rowCount === 0) {
        return NextResponse.json(
          { ok: false, message: "Booking not found" },
          { status: 404 }
        );
      }

      const booking = bookingResult.rows[0];

      // Check if already reminded
      const existingReminder = await client.query(
        `SELECT id, sent_at FROM table_reminder_sends
         WHERE accommodation_booking_id = $1
         ORDER BY sent_at DESC LIMIT 1`,
        [booking_id]
      );

      if (existingReminder.rowCount && existingReminder.rowCount > 0) {
        return NextResponse.json({
          ok: true,
          already_sent: true,
          sent_at: existingReminder.rows[0].sent_at,
          dry_run: DRY_RUN,
          message: "Reminder already sent for this booking",
        });
      }

      // Build the email
      const checkinPretty = new Date(booking.checkin_date).toLocaleDateString(
        "en-GB",
        { weekday: "long", day: "numeric", month: "long" }
      );

      const firstName = extractFirstName(booking.guest_name || "there");

      const subject = `Dinner at The Olde Malthouse Inn — ${new Date(booking.checkin_date).toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" })}`;
      const bodyText = `Hi ${firstName},

We're looking forward to having you with us at The Olde Malthouse Inn
from ${checkinPretty}.

While you're staying, would you like to book a table for dinner?
We're proud of our kitchen and our cellar, and our restaurant fills
up early in season.

Just hit reply with your preferred date, time and party size and
we'll sort it. Or book online at:

  https://www.malthousetintagel.com/book-a-table

Warm wishes,
The Malthouse Team
info@malthousetintagel.com`;

      let gmailMessageId: string | null = null;

      if (!DRY_RUN) {
        // Actually send the email via google-fetch
        try {
          const gfResp = await fetch(`${GF_URL}/send/info`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              to: guest_email,
              subject,
              body_text: bodyText,
              reply_to: "info@malthousetintagel.com",
            }),
          });

          if (!gfResp.ok) {
            throw new Error(`google-fetch returned ${gfResp.status}`);
          }

          const gfData = await gfResp.json();
          gmailMessageId = gfData.message_id || null;
        } catch (sendErr) {
          console.error("Failed to send email:", sendErr);
          return NextResponse.json(
            { ok: false, message: `Failed to send email: ${(sendErr as Error).message}` },
            { status: 502 }
          );
        }
      }

      // Log the send in table_reminder_sends
      await client.query(
        `INSERT INTO table_reminder_sends
           (accommodation_booking_id, guest_name, guest_email,
            gmail_message_id, status, realm)
         VALUES ($1, $2, $3, $4, $5, 'work')
         ON CONFLICT (accommodation_booking_id) DO NOTHING`,
        [
          booking_id,
          booking.guest_name,
          guest_email,
          gmailMessageId || `dry-run-${Date.now()}`,
          DRY_RUN ? "dry_run" : "sent",
        ]
      );

      return NextResponse.json({
        ok: true,
        dry_run: DRY_RUN,
        message: DRY_RUN
          ? `DRY RUN: Would send dinner invitation to ${guest_email} (${firstName})`
          : `Dinner invitation sent to ${guest_email}`,
        gmail_message_id: gmailMessageId,
      });
    }, { entity: '1' });
  } catch (e) {
    console.error("dinner/remind error:", e);
    return NextResponse.json(
      { ok: false, message: (e as Error).message },
      { status: 500 }
    );
  }
}

function extractFirstName(full: string): string {
  if (!full) return "there";
  // Handle concatenated names like "AugustaTaddei"
  const m = full.match(/^([A-Z][a-z]+)/);
  if (m) return m[1];
  // Handle space-separated names
  const parts = full.split(" ");
  return parts[0] || "there";
}
