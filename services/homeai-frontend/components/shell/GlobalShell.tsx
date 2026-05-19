'use client';

import { usePathname, useSearchParams } from 'next/navigation';
import { Sidebar } from './Sidebar';
import { TopBar } from './TopBar';
import { BottomTabs } from './BottomTabs';
import { useEditMode } from '@/components/sandbox/EditModeContext';

export function GlobalShell({ children }: { children: React.ReactNode }) {
  const { editing } = useEditMode();
  const pathname = usePathname();
  const sp = useSearchParams();
  // Day-view mode: dashboard root + ?date=… that isn't today.
  const dateParam = sp.get('date');
  const today = new Date();
  const todayIso = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
  const dayMode = pathname === '/' && dateParam && dateParam !== todayIso;
  const bg = dayMode ? 'bg-amber-50/40' : 'bg-ink-0';
  return (
    <div className={`min-h-screen ${bg} ${editing ? 'sandbox-on' : ''}`}>
      {/* Desktop sidebar */}
      <Sidebar />
      <div className="lg:pl-56">
        <TopBar />
        <main className="px-3 pb-24 pt-3 lg:px-6 lg:pb-6 lg:pt-4">
          {children}
        </main>
      </div>
      {/* Mobile bottom tabs */}
      <BottomTabs />
    </div>
  );
}
