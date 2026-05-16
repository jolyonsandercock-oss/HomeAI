'use client';

import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';

interface Reservation {
  id: number;
  reservation_at: string;
  guest_name: string | null;
  party_size: number | null;
  booking_type: string | null;
  source_ref: string | null;
}

export default function RestaurantPage() {
  const list = useSlug<Reservation>('frontend_restaurant_today', {}, { refetchInterval: 60_000 });
  const total = list.data?.length ?? 0;
  const pax   = list.data?.reduce((s, r) => s + (r.party_size ?? 0), 0) ?? 0;

  return (
    <div className="space-y-6">
      <SandboxWrapper id="restaurant.kpi" label="Restaurant KPIs">
        <Section title="Tonight on the book">
          <div className="grid grid-cols-3 gap-3">
            <KPICard label="Bookings" value={total} loading={list.isLoading} />
            <KPICard label="Pax total" value={pax} loading={list.isLoading} />
            <KPICard label="Avg party" value={total ? (pax / total).toFixed(1) : '—'} loading={list.isLoading} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="restaurant.runsheet" label="Run sheet">
        <Section title="Run sheet">
          {list.isLoading ? (
            <PlaceholderState message="Loading reservations…" />
          ) : list.data && list.data.length > 0 ? (
            <div className="tile">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-2 font-medium">Time</th>
                    <th className="text-left font-medium">Guest</th>
                    <th className="text-left font-medium">Pax</th>
                    <th className="text-left font-medium">Type</th>
                  </tr>
                </thead>
                <tbody>
                  {list.data.map((r) => (
                    <tr key={r.id} className="border-t border-ink-200">
                      <td className="py-2 font-mono text-ink-700">
                        {new Date(r.reservation_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}
                      </td>
                      <td className="font-medium text-ink-900">{r.guest_name ?? '—'}</td>
                      <td className="font-mono text-ink-700">{r.party_size ?? '?'}</td>
                      <td className="text-xs text-ink-500">{r.booking_type ?? r.source_ref}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <PlaceholderState message="No reservations on the book for today." />
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="restaurant.menu-perf" label="Menu performance">
        <Section title="Menu performance">
          <PlaceholderState
            message="Menu performance pending"
            hint="Needs ICRTouch line-level item data ingested (per-PLU sales). Captured in touchoffice_plu_sales when scraper is wired; backend pipeline still in progress." />
        </Section>
      </SandboxWrapper>
    </div>
  );
}
