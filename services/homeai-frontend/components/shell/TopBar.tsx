'use client';

import { usePathname, useSearchParams } from 'next/navigation';
import { DateTimeClock } from './DateTimeClock';
import { GlobalSearch } from './GlobalSearch';
import { EditModeToggle } from '@/components/sandbox/EditModeToggle';
import { Menu } from 'lucide-react';

const titles: Record<string, string> = {
  '/': 'Dashboard',
  '/sales': 'Sales',
  '/rooms': 'Rooms',
  '/restaurant': 'Restaurant',
  '/bar': 'Bar',
  '/cafe': 'Café',
  '/staff': 'Staff',
  '/comms': 'Communications',
  '/tasks': 'Tasks',
  '/admin': 'Admin',
  '/backend': 'Back-end',
};

function dayBadge(iso: string | null): string | null {
  if (!iso) return null;
  // ISO date stays local; new Date('YYYY-MM-DD') is parsed as UTC midnight,
  // which can flip a day in negative TZ. We slice the parts directly.
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return null;
  const today = new Date();
  const todayIso = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
  if (iso === todayIso) return null; // not "in the past/future" relative to today
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  const day = d.toLocaleDateString('en-GB', { weekday: 'short' }).toUpperCase();
  const dom = String(d.getDate());
  const mon = d.toLocaleDateString('en-GB', { month: 'short' }).toUpperCase();
  return `${day} ${dom} ${mon}`;
}

export function TopBar() {
  const pathname = usePathname();
  const sp = useSearchParams();
  const dateParam = sp.get('date');
  const title = titles[pathname] ?? 'Home AI';
  const badge = pathname === '/' ? dayBadge(dateParam) : null;
  return (
    <header className="sticky top-0 z-10 bg-ink-0/85 backdrop-blur border-b border-ink-200">
      <div className="flex items-center gap-3 px-3 py-2 lg:px-6 lg:py-3">
        <button className="lg:hidden text-ink-500 -ml-1 p-1.5 rounded-md hover:bg-ink-100">
          <Menu size={20} />
        </button>
        <div className="text-sm text-ink-700 font-medium">{title}</div>
        {badge && (
          <span className="text-xs font-mono font-bold uppercase tracking-wider px-2 py-0.5 rounded bg-amber-500/20 text-amber-500">
            · {badge}
          </span>
        )}
        <div className="flex-1" />
        <GlobalSearch />
        <EditModeToggle />
        <DateTimeClock />
      </div>
    </header>
  );
}
