'use client';

import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { KPICard } from '@/components/ui/KPICard';

export default function CommsPage() {
  return (
    <div className="space-y-6">
      <SandboxWrapper id="comms.reviews" label="Reviews panel">
        <Section title="Reviews">
          <PlaceholderState
            message="Review aggregation pending"
            hint="Google Business + TripAdvisor + Booking.com review API integrations are queued. For now the daily review nudge (U120 guest.review_nudge_day2) drafts WA messages day+2 after checkout once OAuth is live." />
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="comms.email" label="Email summary">
        <Section title="Email">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <KPICard label="Inbox queue" value="—" />
            <KPICard label="Email tasks open" value="—" />
            <KPICard label="Classifier uncertain" value="—" />
          </div>
          <PlaceholderState
            message="Pending Gmail OAuth re-auth"
            hint="3 consumer Gmail OAuth tokens expired (jo, bot, pounana). Rotate with /home_ai/scripts/oauth/redo-google-oauth.sh — see runbook. Until then no inbound polling." />
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="comms.wa" label="WhatsApp outbound queue">
        <Section title="WhatsApp drafts awaiting approval">
          <PlaceholderState
            message="Will wire to /api/slug/wa_outbound_pending"
            hint="Backed by U118 wa_outbound_queue + U119 staff drafter + U120 visitor drafter. Awaiting paired WhatsApp Web sessions (see PAIRING.md)." />
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="comms.social" label="Social stats">
        <Section title="Social">
          <PlaceholderState
            message="Social media integrations pending"
            hint="Insta/Facebook insights APIs scoped but not built. Roadmapped." />
        </Section>
      </SandboxWrapper>
    </div>
  );
}
