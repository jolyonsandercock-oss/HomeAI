'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { NAV } from './nav';

export function Sidebar() {
  const pathname = usePathname();
  return (
    <aside className="hidden lg:block fixed left-0 top-0 bottom-0 w-56 bg-ink-50 border-r border-ink-200 z-20">
      <div className="px-4 py-5 border-b border-ink-200">
        <div className="font-mono text-sm tracking-wider text-amber-500">HOME AI</div>
        <div className="text-xs text-ink-500 mt-0.5">Olde Malthouse · Tintagel</div>
      </div>
      <nav className="px-2 py-3 space-y-0.5">
        {NAV.map(({ href, label, icon: Icon }) => {
          const active = pathname === href || (href !== '/' && pathname.startsWith(href));
          return (
            <Link key={href} href={href}
              aria-current={active ? 'page' : undefined}
              className={
                'flex items-center gap-3 px-3 py-2 rounded-md text-sm transition-colors ' +
                'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 ' +
                (active
                  ? 'bg-ink-100 text-ink-900'
                  : 'text-ink-600 hover:bg-ink-100 hover:text-ink-800')
              }>
              <Icon size={16} className={active ? 'text-amber-500' : ''} />
              <span>{label}</span>
            </Link>
          );
        })}
      </nav>
    </aside>
  );
}
