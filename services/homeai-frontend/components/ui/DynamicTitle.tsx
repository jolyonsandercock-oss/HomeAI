'use client';

import { usePathname, useSearchParams } from 'next/navigation';
import { useEffect } from 'react';

export function DynamicTitle() {
  const pathname = usePathname();
  const searchParams = useSearchParams();

  useEffect(() => {
    const date = searchParams.get('date');
    const parts: string[] = [];

    if (date) {
      const d = new Date(date + 'T12:00:00');
      parts.push(d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }));
    }

    // Map path to label
    if (pathname === '/' || pathname === '/app') parts.push('Mission Control');
    else if (pathname === '/sales') parts.push('Sales');
    else if (pathname === '/staff') parts.push('Staff');
    else if (pathname === '/bar') parts.push('Bar');
    else if (pathname === '/cafe') parts.push('Cafe');
    else if (pathname === '/restaurant') parts.push('Restaurant');
    else if (pathname === '/rooms') parts.push('Rooms');
    else if (pathname === '/comms') parts.push('Comms');
    else if (pathname === '/admin') parts.push('Admin');
    else if (pathname === '/tasks') parts.push('Tasks');

    parts.push('Home AI');
    document.title = parts.join(' \u2014 ');
  }, [pathname, searchParams]);

  return null;
}
