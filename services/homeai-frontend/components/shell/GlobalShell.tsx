'use client';

import { Sidebar } from './Sidebar';
import { TopBar } from './TopBar';
import { BottomTabs } from './BottomTabs';
import { useEditMode } from '@/components/sandbox/EditModeContext';

export function GlobalShell({ children }: { children: React.ReactNode }) {
  const { editing } = useEditMode();
  return (
    <div className={`min-h-screen bg-ink-0 ${editing ? 'sandbox-on' : ''}`}>
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
