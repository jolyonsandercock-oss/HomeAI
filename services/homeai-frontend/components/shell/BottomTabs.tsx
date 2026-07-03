'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useState } from 'react';
import { Menu } from 'lucide-react';
import { NAV } from './nav';

// Hermes B2: previously the bottom bar showed only `mobile: true` items
// (5 of 11), so >50% of the app was unreachable from mobile. Now we keep
// the 4 most-used items as primary tabs and add a "More" tab that opens
// a sheet revealing every other nav item.

export function BottomTabs() {
  const pathname = usePathname();
  const [moreOpen, setMoreOpen] = useState(false);
  const primary = NAV.filter(n => n.mobile).slice(0, 4);
  const secondary = NAV.filter(n => !primary.some(p => p.href === n.href));

  const closeMore = () => setMoreOpen(false);

  return (
    <>
      {moreOpen && (
        <>
          <button
            aria-label="Close menu"
            onClick={closeMore}
            className="lg:hidden fixed inset-0 bg-black/60 z-40 cursor-default"
          />
          <nav
            aria-label="More navigation"
            id="bottom-tabs-more"
            className="lg:hidden fixed bottom-14 inset-x-0 bg-ink-50 border-t border-ink-200 z-50 max-h-[60vh] overflow-y-auto"
          >
            <ul className="grid grid-cols-3 sm:grid-cols-4 gap-1 p-3">
              {secondary.map(({ href, label, icon: Icon, external }) => {
                const active = pathname === href || (href !== '/' && pathname.startsWith(href));
                const cls =
                  'flex flex-col items-center justify-center gap-1 py-3 rounded text-xs ' +
                  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 ' +
                  (active ? 'bg-ink-100 text-amber-500' : 'text-ink-700 hover:bg-ink-100');
                return (
                  <li key={href}>
                    {external ? (
                      // Outside the /app basePath (legacy dashboard page) —
                      // plain <a> so next/link doesn't prefix the href.
                      <a href={href} onClick={closeMore} className={cls}>
                        <Icon size={20} />
                        <span>{label}</span>
                      </a>
                    ) : (
                      <Link
                        href={href}
                        onClick={closeMore}
                        aria-current={active ? 'page' : undefined}
                        className={cls}
                      >
                        <Icon size={20} />
                        <span>{label}</span>
                      </Link>
                    )}
                  </li>
                );
              })}
            </ul>
          </nav>
        </>
      )}

      <nav
        aria-label="Primary navigation"
        className="lg:hidden fixed bottom-0 inset-x-0 bg-ink-50 border-t border-ink-200 z-30"
      >
        <div className="grid grid-cols-5">
          {primary.map(({ href, label, icon: Icon }) => {
            const active = pathname === href || (href !== '/' && pathname.startsWith(href));
            return (
              <Link key={href} href={href}
                aria-current={active ? 'page' : undefined}
                onClick={closeMore}
                className={
                  'flex flex-col items-center justify-center gap-1 py-2.5 text-xs ' +
                  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-inset ' +
                  (active ? 'text-amber-500' : 'text-ink-500')
                }>
                <Icon size={20} />
                <span>{label}</span>
              </Link>
            );
          })}
          <button
            type="button"
            aria-expanded={moreOpen}
            aria-controls="bottom-tabs-more"
            onClick={() => setMoreOpen(v => !v)}
            className={
              'flex flex-col items-center justify-center gap-1 py-2.5 text-xs ' +
              'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-inset ' +
              (moreOpen ? 'text-amber-500' : 'text-ink-500')
            }
          >
            <Menu size={20} />
            <span>More</span>
          </button>
        </div>
      </nav>
    </>
  );
}
