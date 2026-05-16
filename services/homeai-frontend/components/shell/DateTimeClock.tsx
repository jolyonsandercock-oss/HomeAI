'use client';

import { useEffect, useState } from 'react';

export function DateTimeClock() {
  const [now, setNow] = useState<Date | null>(null);
  useEffect(() => {
    setNow(new Date());
    const t = setInterval(() => setNow(new Date()), 30_000);
    return () => clearInterval(t);
  }, []);
  if (!now) return <div className="font-mono text-xs text-ink-500 w-32 h-4" />;
  const date = now.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
  const time = now.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  return (
    <div className="hidden sm:flex items-baseline gap-2 font-mono text-xs">
      <span className="text-ink-500">{date}</span>
      <span className="text-ink-700">{time}</span>
    </div>
  );
}
