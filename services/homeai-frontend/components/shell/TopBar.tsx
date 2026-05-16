'use client';

import { usePathname } from 'next/navigation';
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

export function TopBar() {
  const pathname = usePathname();
  const title = titles[pathname] ?? 'Home AI';
  return (
    <header className="sticky top-0 z-10 bg-ink-0/85 backdrop-blur border-b border-ink-200">
      <div className="flex items-center gap-3 px-3 py-2 lg:px-6 lg:py-3">
        <button className="lg:hidden text-ink-500 -ml-1 p-1.5 rounded-md hover:bg-ink-100">
          <Menu size={20} />
        </button>
        <div className="text-sm text-ink-700 font-medium">{title}</div>
        <div className="flex-1" />
        <GlobalSearch />
        <EditModeToggle />
        <DateTimeClock />
      </div>
    </header>
  );
}
