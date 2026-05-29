'use client';

// Hermes D3: online/offline indicator. Renders a thin banner across the top
// when the browser reports the network is down — gives users a real reason
// for why the dashboard might be showing stale numbers.

import { useEffect, useState } from 'react';

export function OnlineIndicator() {
  // SSR-safe default: assume online; flip on mount if not.
  const [online, setOnline] = useState(true);

  useEffect(() => {
    const update = () => setOnline(typeof navigator !== 'undefined' ? navigator.onLine : true);
    update();
    window.addEventListener('online', update);
    window.addEventListener('offline', update);
    return () => {
      window.removeEventListener('online', update);
      window.removeEventListener('offline', update);
    };
  }, []);

  if (online) return null;

  return (
    <div
      role="status"
      className="fixed top-0 inset-x-0 z-50 bg-red-700 text-white text-xs text-center py-1"
    >
      ⚠ Offline — data may be stale. Reconnecting…
    </div>
  );
}
