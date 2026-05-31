'use client';

import { Suspense } from 'react';
import { usePathname, useSearchParams } from 'next/navigation';
import { Sidebar } from './Sidebar';
import { TopBar } from './TopBar';
import { BottomTabs } from './BottomTabs';
import { useEditMode } from '@/components/sandbox/EditModeContext';
import { ErrorBoundary } from '@/components/ui/ErrorBoundary';
import { OnlineIndicator } from '@/components/ui/OnlineIndicator';

// Inner component does the useSearchParams() read; wrapped in Suspense
// at export so Next.js's static prerender pass doesn't bail.
function GlobalShellInner({ children }: { children: React.ReactNode }) {
  const { editing } = useEditMode();
  const pathname = usePathname();
  const sp = useSearchParams();
  const dateParam = sp.get('date');
  const today = new Date();
  const todayIso = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
  const dayMode = pathname === '/' && dateParam && dateParam !== todayIso;
  const bg = dayMode ? 'bg-amber-50/40' : 'bg-ink-0';
  return (
    <div className={`min-h-screen ${bg} ${editing ? 'sandbox-on' : ''}`}>
      <OnlineIndicator />
      <Sidebar />
      <div className="lg:pl-56">
        <TopBar />
        <main className="mx-auto max-w-[1760px] px-3 pb-24 pt-3 lg:px-6 lg:pb-6 lg:pt-4">
          <ErrorBoundary>{children}</ErrorBoundary>
        </main>
      </div>
      <BottomTabs />
    </div>
  );
}

export function GlobalShell({ children }: { children: React.ReactNode }) {
  return (
    <Suspense fallback={<div className="min-h-screen bg-ink-0" />}>
      <GlobalShellInner>{children}</GlobalShellInner>
    </Suspense>
  );
}
