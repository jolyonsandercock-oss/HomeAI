'use client';

import Link from 'next/link';
import { usePathname, useSearchParams } from 'next/navigation';
import { NAV, NavItem } from './nav';
import { Briefcase, User } from 'lucide-react';
import { SnagTicker } from './SnagTicker';
import { BirthdayTicker } from './BirthdayTicker';

// External entries (e.g. /counterparty-review on the build-dashboard) live on
// the same FQDN but outside the /app basePath, so they must render as plain
// <a> — next/link would prefix the basePath and 404.
function NavEntry({ item, active }: { item: NavItem; active: boolean }) {
  const { href, label, icon: Icon, external } = item;
  const className =
    'flex items-center gap-3 px-3 py-2 rounded-md text-sm transition-colors ' +
    'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 ' +
    (active
      ? 'bg-ink-100 text-ink-900'
      : 'text-ink-600 hover:bg-ink-100 hover:text-ink-800');
  const body = (
    <>
      <Icon size={16} className={active ? 'text-amber-500' : ''} />
      <span>{label}</span>
    </>
  );
  if (external) {
    return <a href={href} className={className}>{body}</a>;
  }
  return (
    <Link href={href} aria-current={active ? 'page' : undefined} className={className}>
      {body}
    </Link>
  );
}

export function Sidebar() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const realm = (searchParams.get('realm') as 'work' | 'personal') || 'work';

  const toggleRealm = () => {
    const next = realm === 'work' ? 'personal' : 'work';
    const url = new URL(window.location.href);
    url.searchParams.set('realm', next);
    window.location.href = url.toString();
  };

  const visibleNav = NAV.filter(() => true); // personal sees all, work filters below

  const workItems = NAV.filter(i => i.realm === 'work');
  const personalItems = NAV.filter(i => i.realm === 'personal');

  return (
    <aside className="hidden lg:block fixed left-0 top-0 bottom-0 w-56 bg-ink-50 border-r border-ink-200 z-20">
      <div className="px-4 py-4 border-b border-ink-200">
        <div className="font-mono text-sm tracking-wider text-amber-500">HOME AI</div>
        <div className="text-xs text-ink-500 mt-0.5">Olde Malthouse · Tintagel</div>
        
        {/* Realm Toggle */}
        <button
          onClick={toggleRealm}
          className="mt-3 w-full flex items-center gap-2 px-3 py-2 rounded-md text-xs font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500"
          style={{
            backgroundColor: realm === 'personal' ? 'rgba(245,158,11,0.15)' : 'rgba(245,158,11,0.05)',
            color: '#f59e0b'
          }}
        >
          {realm === 'work' ? (
            <><Briefcase size={14} /><span>Work view</span></>
          ) : (
            <><User size={14} /><span>Personal view</span></>
          )}
        </button>
      </div>
      <nav className="px-2 py-3 space-y-0.5 overflow-y-auto" style={{ maxHeight: 'calc(100vh - 140px)' }}>
        {realm === 'personal' ? (
          // Personal mode — all items, no divider
          NAV.map((item) => {
            const active = pathname === item.href || (item.href !== '/' && pathname.startsWith(item.href));
            return <NavEntry key={item.href} item={item} active={active} />;
          })
        ) : (
          // Work mode — work items, then personal at bottom with subtle divider
          <>
            {workItems.map((item) => {
              const active = pathname === item.href || (item.href !== '/' && pathname.startsWith(item.href));
              return <NavEntry key={item.href} item={item} active={active} />;
            })}
            <div className="my-2 border-t border-ink-200" />
            <div className="text-2xs text-ink-400 uppercase tracking-wider px-3 py-1">Personal</div>
            {personalItems.map((item) => {
              const active = pathname === item.href || (item.href !== '/' && pathname.startsWith(item.href));
              return <NavEntry key={item.href} item={item} active={active} />;
            })}
          </>
        )}
      </nav>
      <BirthdayTicker />
      <SnagTicker />
    </aside>
  );
}
