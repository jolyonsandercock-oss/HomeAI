'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { NAV } from './nav';

export function BottomTabs() {
  const pathname = usePathname();
  const mobileNav = NAV.filter(n => n.mobile).slice(0, 5);
  return (
    <nav className="lg:hidden fixed bottom-0 inset-x-0 bg-ink-50 border-t border-ink-200 z-30">
      <div className="grid grid-cols-4 sm:grid-cols-5">
        {mobileNav.map(({ href, label, icon: Icon }) => {
          const active = pathname === href || (href !== '/' && pathname.startsWith(href));
          return (
            <Link key={href} href={href}
              className={
                'flex flex-col items-center justify-center gap-1 py-2.5 text-[10px] ' +
                (active ? 'text-amber-500' : 'text-ink-500')
              }>
              <Icon size={20} />
              <span>{label}</span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
