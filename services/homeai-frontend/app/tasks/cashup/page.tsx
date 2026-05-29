'use client';

import { useState, useEffect } from 'react';
import { useSearchParams } from 'next/navigation';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import { AlertTriangle, CheckCircle2 } from 'lucide-react';

interface ReconRow {
  site: 'malthouse' | 'sandwich';
  till_id: string;
  z_read_pence: number;
  cash_taken_pence: number | null;
  card_pence: number | null;
  gratuity_pence: number | null;
  caterpay_pence: number | null;
  collins_deposit_pence: number | null;
  manual_notes: string | null;
  entered_at: string | null;
  variance_pence: number;
}
interface SafeBalance {
  site: string;
  running_balance_pence: number;
  movement_count: number;
  last_movement: string | null;
}

function todayIsoLocal(): string {
  const t = new Date();
  return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(t.getDate()).padStart(2, '0')}`;
}

const BP = process.env.NEXT_PUBLIC_BASE_PATH || '';

export default function CashupPage() {
  const sp = useSearchParams();
  const dateParam = sp.get('date');
  const [date, setDate] = useState(dateParam || todayIsoLocal());

  const recon = useSlug<ReconRow>('cashup_reconciliation_today', { date }, { refetchInterval: 30_000 });
  const safe  = useSlug<SafeBalance>('safe_running_balance', {}, { refetchInterval: 60_000 });

  return (
    <div className="space-y-6">
      <SandboxWrapper id="cashup.header" label="Cash-up day">
        <Section title="End-of-day cash-up">
          <div className="flex items-center gap-3 mb-1 text-xs">
            <label className="flex items-center gap-1">
              <span className="text-ink-500 uppercase tracking-wider">Date</span>
              <input type="date" value={date} onChange={e => setDate(e.target.value)}
                className="bg-ink-100 border border-ink-200 rounded px-2 py-1 text-ink-900" />
            </label>
            <div className="text-xs text-ink-500 ml-auto">
              Variance = (cash + card + caterpay + collins) − Z-read · &gt;£5 highlighted
            </div>
          </div>
        </Section>
      </SandboxWrapper>

      {recon.isLoading ? <PlaceholderState message="Loading reconciliation…" /> :
       recon.data && recon.data.length > 0 ? (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
          {(['malthouse', 'sandwich'] as const).map(site => (
            <SiteCashupPanel key={site} site={site} date={date}
              rows={recon.data!.filter(r => r.site === site)}
              onSubmit={() => recon.refetch()} />
          ))}
        </div>
      ) : <PlaceholderState message="No reconciliation data for this date." />}

      {/* Safe balance */}
      <SandboxWrapper id="cashup.safe" label="Safe">
        <Section title="Safe — current month running balance">
          {safe.isLoading ? <PlaceholderState message="Loading…" /> :
           safe.data && safe.data.length > 0 ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              {safe.data.map(s => (
                <div key={s.site} className="tile">
                  <div className="text-xs uppercase tracking-wider text-ink-500">{s.site}</div>
                  <div className="mt-1 text-2xl font-mono font-semibold text-ink-900">
                    {gbp(s.running_balance_pence / 100)}
                  </div>
                  <div className="text-sm text-ink-500 mt-1">
                    {s.movement_count} movement{s.movement_count === 1 ? '' : 's'} this month
                    {s.last_movement && ` · last on ${new Date(s.last_movement).toLocaleDateString('en-GB')}`}
                  </div>
                </div>
              ))}
            </div>
          ) : <PlaceholderState message="No safe movements this month." />}
          <SafeMovementForm onSubmit={() => safe.refetch()} />
        </Section>
      </SandboxWrapper>
    </div>
  );
}

function SiteCashupPanel({ site, date, rows, onSubmit }: {
  site: 'malthouse' | 'sandwich'; date: string;
  rows: ReconRow[]; onSubmit: () => void;
}) {
  return (
    <SandboxWrapper id={`cashup.${site}`} label={`${site} cashup`}>
      <Section title={`${site === 'malthouse' ? 'Malthouse' : 'Sandwich Bay'}`}>
        <div className="space-y-3">
          {rows.map(r => <TillRow key={r.till_id} row={r} site={site} date={date} onSubmit={onSubmit} />)}
          {rows.length > 1 && (
            <TotalsLine rows={rows} />
          )}
        </div>
      </Section>
    </SandboxWrapper>
  );
}

function TillRow({ row, site, date, onSubmit }: {
  row: ReconRow; site: 'malthouse' | 'sandwich'; date: string; onSubmit: () => void;
}) {
  const [cash, setCash]         = useState<string>(row.cash_taken_pence ? (row.cash_taken_pence / 100).toFixed(2) : '');
  const [caterpay, setCaterpay] = useState<string>(row.caterpay_pence ? (row.caterpay_pence / 100).toFixed(2) : '');
  const [notes, setNotes]       = useState<string>(row.manual_notes ?? '');
  const [saving, setSaving]     = useState(false);
  const [saved, setSaved]       = useState(false);

  useEffect(() => {
    setCash(row.cash_taken_pence ? (row.cash_taken_pence / 100).toFixed(2) : '');
    setCaterpay(row.caterpay_pence ? (row.caterpay_pence / 100).toFixed(2) : '');
    setNotes(row.manual_notes ?? '');
  }, [row]);

  async function submit() {
    setSaving(true); setSaved(false);
    const r = await fetch(`${BP}/api/cashup`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        site, cashup_date: date, till_id: row.till_id,
        cash_taken_pence: cash ? Math.round(parseFloat(cash) * 100) : null,
        caterpay_pence:   caterpay ? Math.round(parseFloat(caterpay) * 100) : null,
        manual_notes:     notes || null,
      }),
    });
    setSaving(false);
    if (r.ok) { setSaved(true); onSubmit(); }
  }

  const variance = row.variance_pence;
  const isBig = Math.abs(variance) > 500;
  const varianceClass = isBig ? 'text-warn' : Math.abs(variance) > 100 ? 'text-amber-500' : 'text-good';

  return (
    <div className="tile">
      <div className="flex items-center justify-between mb-2">
        <div className="text-xs font-semibold uppercase tracking-wider text-ink-700">{row.till_id.replace('till_', '')}</div>
        {row.entered_at && (
          <div className="text-xs text-ink-500 flex items-center gap-1">
            <CheckCircle2 size={10} className="text-good" /> saved
          </div>
        )}
      </div>
      <div className="grid grid-cols-2 gap-x-3 gap-y-1.5 text-sm">
        <div>
          <div className="text-ink-500 uppercase tracking-wider text-xs">Z-read</div>
          <div className="font-mono text-ink-900">{gbp(row.z_read_pence / 100)}</div>
        </div>
        <div>
          <div className="text-ink-500 uppercase tracking-wider text-xs">Card (Dojo)</div>
          <div className="font-mono text-ink-900">{row.card_pence != null ? gbp(row.card_pence / 100) : '—'}</div>
        </div>
        <div>
          <div className="text-ink-500 uppercase tracking-wider text-xs">Cash (counted)</div>
          <input type="number" step="0.01" value={cash} onChange={e => setCash(e.target.value)}
            className="bg-ink-100 border border-ink-200 rounded px-2 py-0.5 w-full font-mono text-ink-900" placeholder="0.00" />
        </div>
        <div>
          <div className="text-ink-500 uppercase tracking-wider text-xs">Caterpay (override)</div>
          <input type="number" step="0.01" value={caterpay} onChange={e => setCaterpay(e.target.value)}
            className="bg-ink-100 border border-ink-200 rounded px-2 py-0.5 w-full font-mono text-ink-900" placeholder="0.00" />
        </div>
        {row.collins_deposit_pence != null && row.collins_deposit_pence > 0 && (
          <div className="col-span-2">
            <div className="text-ink-500 uppercase tracking-wider text-xs">Collins deposits</div>
            <div className="font-mono text-info">{gbp(row.collins_deposit_pence / 100)}</div>
          </div>
        )}
        <div className="col-span-2 mt-1">
          <div className="text-ink-500 uppercase tracking-wider text-xs">Notes</div>
          <input type="text" value={notes} onChange={e => setNotes(e.target.value)}
            className="bg-ink-100 border border-ink-200 rounded px-2 py-0.5 w-full text-ink-900" />
        </div>
      </div>
      <div className="mt-2 pt-2 border-t border-ink-200 flex items-center justify-between">
        <div className="flex items-center gap-2">
          {isBig && <AlertTriangle size={14} className="text-warn" />}
          <div className="text-xs">Variance</div>
          <div className={'font-mono font-semibold ' + varianceClass}>
            {variance >= 0 ? '+' : '−'}{gbp(Math.abs(variance) / 100)}
          </div>
        </div>
        <button onClick={submit} disabled={saving}
          className="text-sm uppercase tracking-wider px-3 py-1 rounded bg-amber-500 text-white hover:bg-amber-600 disabled:opacity-50">
          {saving ? 'Saving…' : saved ? 'Saved' : 'Save'}
        </button>
      </div>
    </div>
  );
}

function TotalsLine({ rows }: { rows: ReconRow[] }) {
  const totals = rows.reduce((acc, r) => ({
    z_read: acc.z_read + r.z_read_pence,
    cash:   acc.cash + (r.cash_taken_pence ?? 0),
    card:   acc.card + (r.card_pence ?? 0),
    caterpay: acc.caterpay + (r.caterpay_pence ?? 0),
    collins:  acc.collins  + (r.collins_deposit_pence ?? 0),
    variance: acc.variance + r.variance_pence,
  }), { z_read: 0, cash: 0, card: 0, caterpay: 0, collins: 0, variance: 0 });

  const isBig = Math.abs(totals.variance) > 500;
  const cls = isBig ? 'text-warn' : Math.abs(totals.variance) > 100 ? 'text-amber-500' : 'text-good';

  return (
    <div className="tile bg-ink-100">
      <div className="text-xs uppercase tracking-wider text-ink-500 mb-1">Site totals</div>
      <div className="grid grid-cols-5 gap-2 text-sm font-mono text-ink-900">
        <div><div className="text-xs text-ink-500 uppercase">Z</div>{gbp(totals.z_read / 100)}</div>
        <div><div className="text-xs text-ink-500 uppercase">Cash</div>{gbp(totals.cash / 100)}</div>
        <div><div className="text-xs text-ink-500 uppercase">Card</div>{gbp(totals.card / 100)}</div>
        <div><div className="text-xs text-ink-500 uppercase">Cpy</div>{gbp(totals.caterpay / 100)}</div>
        <div><div className="text-xs text-ink-500 uppercase">Coll</div>{gbp(totals.collins / 100)}</div>
      </div>
      <div className={'mt-2 pt-1 border-t border-ink-200 text-sm font-semibold ' + cls}>
        Variance: {totals.variance >= 0 ? '+' : '−'}{gbp(Math.abs(totals.variance) / 100)}
      </div>
    </div>
  );
}

function SafeMovementForm({ onSubmit }: { onSubmit: () => void }) {
  const [site, setSite] = useState<'malthouse' | 'sandwich'>('malthouse');
  const [direction, setDirection] = useState<'to_safe' | 'from_safe'>('to_safe');
  const [amount, setAmount] = useState('');
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit() {
    if (!amount) return;
    setBusy(true);
    const r = await fetch(`${BP}/api/safe`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        movement_date: todayIsoLocal(), site, direction,
        amount_pence: Math.round(parseFloat(amount) * 100),
        notes: notes || null,
      }),
    });
    setBusy(false);
    if (r.ok) { setAmount(''); setNotes(''); onSubmit(); }
  }

  return (
    <div className="tile mt-3">
      <div className="text-xs uppercase tracking-wider text-ink-500 mb-2">Log a safe movement</div>
      <div className="grid grid-cols-2 sm:grid-cols-5 gap-2 text-xs items-end">
        <select value={site} onChange={e => setSite(e.target.value as 'malthouse' | 'sandwich')}
          className="bg-ink-100 border border-ink-200 rounded px-2 py-1 text-ink-900">
          <option value="malthouse">Malthouse</option>
          <option value="sandwich">Sandwich Bay</option>
        </select>
        <select value={direction} onChange={e => setDirection(e.target.value as 'to_safe' | 'from_safe')}
          className="bg-ink-100 border border-ink-200 rounded px-2 py-1 text-ink-900">
          <option value="to_safe">→ to safe</option>
          <option value="from_safe">← from safe</option>
        </select>
        <input type="number" step="0.01" value={amount} onChange={e => setAmount(e.target.value)}
          className="bg-ink-100 border border-ink-200 rounded px-2 py-1 font-mono text-ink-900" placeholder="£" />
        <input type="text" value={notes} onChange={e => setNotes(e.target.value)}
          className="bg-ink-100 border border-ink-200 rounded px-2 py-1 text-ink-900" placeholder="notes" />
        <button onClick={submit} disabled={busy || !amount}
          className="text-sm uppercase tracking-wider px-3 py-1 rounded bg-amber-500 text-white hover:bg-amber-600 disabled:opacity-50">
          {busy ? '…' : 'Log'}
        </button>
      </div>
    </div>
  );
}
