'use client';

import { useState, useEffect, useMemo } from 'react';
import { useRouter, useSearchParams, usePathname } from 'next/navigation';
import Link from 'next/link';
import { DateRangePicker, DateRange } from '@/components/ui/DateRangePicker';
import { PollClock } from '@/components/ui/PollClock';
import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { SparkLine } from '@/components/ui/SparkLine';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import clsx from 'clsx';

interface TodayGross { site: string; gross: string }
// U225 T5: wage summary now includes `purchases` (Beverage vendor invoices).
interface BarWage   { days: number; labour: string | null; sales: string | null; purchases: string | null; pct: string | null }
// U225 T5: till groups now expose £ value (total_value) instead of count (total_qty).
interface TillGroup { grp: string; values: number[]; total_value: string }
interface MenuRow {
  site: string;
  course: 'main' | 'starter' | 'dessert' | 'side' | 'drink' | 'other';
  plu_number: string;
  descriptor: string;
  qty: string;
  gross_gbp: string;
  avg_price: string | null;
  rank_in_course: number;
}

const GRP_LABEL: Record<string, string> = {
  beer: 'Beer', wine: 'Wine', cocktail: 'Cocktails',
  spirit: 'Spirits', hot_drink: 'Hot drinks', soft_drink: 'Soft drinks',
};
const GRP_COLOUR: Record<string, string> = {
  beer: '#f59e0b', wine: '#b91c1c', cocktail: '#ec4899',
  spirit: '#a78bfa', hot_drink: '#84cc16', soft_drink: '#06b6d4',
};

// Colour band for wage %: <30 good (green), ≥30 warn (red). Matches the
// existing WagePctBadge convention (threshold 30%, FOH only).
function wagePctTone(pct: number | null): { box: string; text: string; label: string } {
  if (pct == null) return { box: 'bg-ink-100 border-ink-200', text: 'text-ink-500', label: '—' };
  if (pct < 30)    return { box: 'bg-good/10 border-good/40', text: 'text-good', label: `${pct.toFixed(1)}%` };
  return { box: 'bg-warn/10 border-warn/40', text: 'text-warn', label: `${pct.toFixed(1)}%` };
}

const PERIOD_LABELS: Record<number, string> = { 1: 'Yesterday', 7: 'Last 7 days', 30: 'Last 30 days' };

const TABS = ['all', 'pub', 'cafe'] as const;
type Tab = (typeof TABS)[number];

// Drink filter categories (#51)
const DRINK_FILTERS = ['All', 'Beers', 'Wines', 'Spirits', 'Soft Drinks'] as const;
type DrinkFilter = (typeof DRINK_FILTERS)[number];

const DRINK_PATTERNS: Record<Exclude<DrinkFilter, 'All'>, RegExp> = {
  Beers:       /ale|lager|cider|ipa|stout/i,
  Wines:       /wine|chardonnay|sauvignon|pinot|merlot|rosé|rose/i,
  Spirits:     /gin|vodka|whisky|rum|cocktail/i,
  'Soft Drinks': /soda|water|juice|lemonade|cola|pepsi|tonic/i,
};

export default function BarPage() {

  const [range, setRange] = useState<DateRange>({ preset: 'today', start: new Date().toISOString().slice(0, 10), end: new Date().toISOString().slice(0, 10) });
  // #42/#43: fix dateParam to pass proper from/to for range presets so slug re-fetches
  const dateParam = useMemo(() => {
    if (range.preset === 'today' || range.preset === 'yesterday') return { date: range.start } as Record<string, string>;
    return { from: range.start, to: range.end } as Record<string, string>;
  }, [range]);
  const today = useSlug<TodayGross>('frontend_today_gross', dateParam);
  const wage  = useSlug<BarWage>('bar_wage_summary', dateParam);
  const till  = useSlug<TillGroup>('bar_till_groups_spark_7d');
  // #44: menu performance for drinks
  const menu  = useSlug<MenuRow>('menu_performance_by_course_7d', {}, { refetchInterval: 30 * 60_000 });
  // #51: drink filter state
  const [drinkFilter, setDrinkFilter] = useState<DrinkFilter>('All');
  const pub   = today.data?.find(r => r.site === 'malthouse');  const router = useRouter();
  const sp = useSearchParams();
  const pathname = usePathname();
  const initialTab = (TABS.find(t => t === sp.get('tab')) as Tab | undefined) ?? 'all';
  const [tab, setTabState] = useState<Tab>(initialTab);
  const setTab = (t: Tab) => {
    setTabState(t);
    const params = new URLSearchParams(sp.toString());
    if (t === 'all') params.delete('tab'); else params.set('tab', t);
    const q = params.toString();
    router.replace(q ? `${pathname}?${q}` : pathname, { scroll: false });
  };
  useEffect(() => {
    const urlTab = sp.get('tab');
    if (urlTab && TABS.includes(urlTab as Tab) && urlTab !== tab) {
      setTabState(urlTab as Tab);
    }
  }, [sp]);
  const poller = useSlug<{ source: string; last_poll: string }>('sales_last_poll_per_source', {}, { refetchInterval: 60_000 });
  const pollFor = (source: string) => (poller.data ?? []).find((p: any) => p.source === source)?.last_poll ?? null;

  const w = (d: number) => wage.data?.find(x => Number(x.days) === d);

  // #44 + #51: filtered drinks from menu performance
  const drinks = useMemo(() => {
    const all = (menu.data ?? [])
      .filter(r => r.site === 'malthouse' && r.course === 'drink');
    if (drinkFilter === 'All') return all;
    const pat = DRINK_PATTERNS[drinkFilter];
    return all.filter(r => pat.test(r.descriptor));
  }, [menu.data, drinkFilter]);

  const top10    = useMemo(() => [...drinks].sort((a, b) => parseFloat(b.gross_gbp) - parseFloat(a.gross_gbp)).slice(0, 10), [drinks]);
  const bottom10 = useMemo(() => [...drinks].filter(d => parseFloat(d.gross_gbp) > 0).sort((a, b) => parseFloat(a.gross_gbp) - parseFloat(b.gross_gbp)).slice(0, 10), [drinks]);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between flex-wrap gap-3">
        <DateRangePicker value={range} onChange={setRange} />
        <div className="flex items-center gap-2">
          <div className="flex bg-ink-100 border border-ink-200 rounded-md overflow-hidden text-xs">
            {TABS.map((t) => (
              <button key={t} onClick={() => setTab(t)}
                className={'px-3 py-1.5 capitalize ' + (tab === t ? 'bg-amber-500 text-ink-0' : 'text-ink-600 hover:text-ink-800')}>{t}</button>
            ))}
          </div>
          <div className="flex items-center gap-1 text-xs text-ink-500">
            <span>polls:</span>
            <PollClock lastPoll={pollFor('touchoffice_malthouse')} label="touchoffice pub" />
            <PollClock lastPoll={pollFor('touchoffice_sandwich')} label="touchoffice cafe" />
          </div>
        </div>
      </div>

      <SandboxWrapper id="bar.kpi" label="Bar KPIs">
        <Section title="Bar — today">
          <KPICard label="Pub gross today" size="xl" value={gbp(pub?.gross ?? 0)} loading={today.isLoading} />
          <div className="text-xs text-ink-500 mt-1">
            <Link href="/app/invoices?department=bar" className="text-amber-500 hover:text-amber-400 underline">
              → View bar invoices
            </Link>
          </div>
        </Section>
      </SandboxWrapper>

      {/* U225 T5: 3 period boxes (Yesterday / 7d / 30d). Each shows wage £,
          sales £, purchases £ (Beverage invoices), wage %, colour-coded. */}
      <SandboxWrapper id="bar.period-boxes">
        <Section title="Wage · sales · purchases">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            {[1, 7, 30].map(d => {
              const r = w(d);
              const pct = r?.pct ? parseFloat(r.pct) : null;
              const labour    = r?.labour    ? parseFloat(r.labour)    : null;
              const sales     = r?.sales     ? parseFloat(r.sales)     : null;
              const purchases = r?.purchases ? parseFloat(r.purchases) : null;
              const tone = wagePctTone(pct);
              return (
                <div key={d} className={clsx('tile border rounded-lg p-3 transition-colors', tone.box)}>
                  <div className="flex items-baseline justify-between">
                    <div className="label">{PERIOD_LABELS[d]}</div>
                    <div className={clsx('font-mono font-bold text-lg', tone.text)}>{tone.label}</div>
                  </div>
                  <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
                    <div>
                      <div className="text-ink-500 uppercase text-xs tracking-wide">Wage</div>
                      <div className="font-mono text-ink-900 mt-0.5">
                        {labour != null ? gbp(labour, 0) : <span className="text-ink-400">—</span>}
                      </div>
                    </div>
                    <div>
                      <div className="text-ink-500 uppercase text-xs tracking-wide">Sales</div>
                      <div className="font-mono text-ink-900 mt-0.5">
                        {sales != null ? gbp(sales, 0) : <span className="text-ink-400">—</span>}
                      </div>
                    </div>
                    <div>
                      <div className="text-ink-500 uppercase text-xs tracking-wide">Purch.</div>
                      <div className="font-mono text-ink-900 mt-0.5">
                        {purchases != null ? gbp(purchases, 0) : <span className="text-ink-400">—</span>}
                      </div>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
          <div className="text-xs text-ink-500 mt-1">
            Wage % = FOH labour ÷ Pub sales · threshold 30%.
            Purchases = Beverage vendor invoices. {' '}
            <Link href="/app/invoices" className="text-amber-500 hover:text-amber-400 underline">
              → View invoices / COGS
            </Link>
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="bar.till-sparks">
        <Section title="Till performance — 7-day £ per drink group">
          {till.isLoading ? <PlaceholderState message="Loading till data…" /> :
           till.data && till.data.length > 0 ? (
            <div className="max-h-[500px] overflow-y-auto border border-ink-100 rounded"><div className="grid grid-cols-2 sm:grid-cols-3 gap-3 p-1">
              {till.data.map(g => (
                <div key={g.grp} className="tile">
                  <div className="label">{GRP_LABEL[g.grp] ?? g.grp}</div>
                  <div className="kpi mt-1">{gbp(Number(g.total_value) || 0, 0)}</div>
                  <div className="text-xs text-ink-500 mt-0.5">£ over 7 days</div>
                  <div className="mt-2 h-8 opacity-70">
                    <SparkLine values={g.values.map(v => Number(v) || 0)} colour={GRP_COLOUR[g.grp]} />
                  </div>
                  <Link
                    href={`/app/invoices?department=bar&q=${encodeURIComponent(GRP_LABEL[g.grp] || g.grp)}`}
                    className="text-xs text-amber-500 hover:text-amber-400 underline mt-1 inline-block"
                  >
                    → Drill into invoices
                  </Link>
                </div>
              ))}
            </div>
            </div>
          ) : <PlaceholderState message="No till data yet." />}
        </Section>
      </SandboxWrapper>

      {/* #44 + #51: Top 10 / Bottom 10 drinks with filter */}
      <SandboxWrapper id="bar.drink-leaderboard" label="Drink Leaderboard">
        <Section title="Top & Bottom 10 Drinks (7 days)">
          {/* #51: drink filter tabs */}
          <div className="flex items-center gap-2 mb-4">
            <span className="text-xs text-ink-500">Filter:</span>
            <div className="flex bg-ink-100 border border-ink-200 rounded-md overflow-hidden text-xs">
              {DRINK_FILTERS.map((f) => (
                <button key={f} onClick={() => setDrinkFilter(f)}
                  className={'px-2.5 py-1.5 ' + (drinkFilter === f ? 'bg-amber-500 text-ink-0' : 'text-ink-600 hover:text-ink-800')}>{f}</button>
              ))}
            </div>
            <span className="text-xs text-ink-400 ml-2">{drinks.length} drinks</span>
          </div>
          {menu.isLoading ? <PlaceholderState message="Loading drink performance…" /> :
           drinks.length === 0 ? <PlaceholderState message="No drink data available." /> : (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              {/* Top 10 */}
              <div>
                <div className="text-xs uppercase tracking-wide text-ink-500 mb-2 font-semibold">Top 10 by Revenue</div>
                <div className="border border-ink-100 rounded overflow-hidden">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="bg-ink-50 text-ink-500 uppercase tracking-wide">
                        <th className="text-left px-2 py-1.5">#</th>
                        <th className="text-left px-2 py-1.5">Drink</th>
                        <th className="text-right px-2 py-1.5">Qty</th>
                        <th className="text-right px-2 py-1.5">Gross</th>
                      </tr>
                    </thead>
                    <tbody>
                      {top10.map((d, i) => (
                        <tr key={d.plu_number} className={i % 2 === 0 ? 'bg-ink-0' : 'bg-ink-50/50'}>
                          <td className="px-2 py-1.5 text-ink-400 font-mono">{i + 1}</td>
                          <td className="px-2 py-1.5 truncate max-w-[160px]" title={d.descriptor}>{d.descriptor}</td>
                          <td className="px-2 py-1.5 text-right font-mono">{parseFloat(d.qty).toFixed(0)}</td>
                          <td className="px-2 py-1.5 text-right font-mono">{gbp(parseFloat(d.gross_gbp) || 0, 0)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
              {/* Bottom 10 */}
              <div>
                <div className="text-xs uppercase tracking-wide text-ink-500 mb-2 font-semibold">Bottom 10 by Revenue</div>
                <div className="border border-ink-100 rounded overflow-hidden">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="bg-ink-50 text-ink-500 uppercase tracking-wide">
                        <th className="text-left px-2 py-1.5">#</th>
                        <th className="text-left px-2 py-1.5">Drink</th>
                        <th className="text-right px-2 py-1.5">Qty</th>
                        <th className="text-right px-2 py-1.5">Gross</th>
                      </tr>
                    </thead>
                    <tbody>
                      {bottom10.map((d, i) => (
                        <tr key={d.plu_number} className={i % 2 === 0 ? 'bg-ink-0' : 'bg-ink-50/50'}>
                          <td className="px-2 py-1.5 text-ink-400 font-mono">{i + 1}</td>
                          <td className="px-2 py-1.5 truncate max-w-[160px]" title={d.descriptor}>{d.descriptor}</td>
                          <td className="px-2 py-1.5 text-right font-mono">{parseFloat(d.qty).toFixed(0)}</td>
                          <td className="px-2 py-1.5 text-right font-mono">{gbp(parseFloat(d.gross_gbp) || 0, 0)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          )}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
