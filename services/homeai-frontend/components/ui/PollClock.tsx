'use client';

import { useEffect, useState } from 'react';
import { Clock } from 'lucide-react';

interface Props {
  lastPoll: string | Date | null | undefined;
  /** Age in minutes at which the badge fades to fully red. Default 15. */
  redAtMin?: number;
  /** Below this many minutes the badge is fully green. Default 3. */
  greenBelowMin?: number;
  /** Treat as stuck (red + flashing) above this. Default redAtMin. */
  stuckAboveMin?: number;
  label?: string;
}

export function PollClock({ lastPoll, redAtMin = 15, greenBelowMin = 3, stuckAboveMin, label }: Props) {
  const stuck = stuckAboveMin ?? redAtMin;
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(id);
  }, []);

  if (!lastPoll) {
    return (
      <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] bg-red-900/40 text-red-300 animate-pulse" title="never polled">
        <Clock size={10} /> never
      </span>
    );
  }

  const t = typeof lastPoll === 'string' ? new Date(lastPoll).getTime() : lastPoll.getTime();
  const ageMin = (now - t) / 60_000;

  let bg: string, fg: string, flash = false;
  if (ageMin >= stuck) {
    bg = 'bg-red-900/60'; fg = 'text-red-200'; flash = true;
  } else if (ageMin <= greenBelowMin) {
    bg = 'bg-emerald-900/40'; fg = 'text-emerald-300';
  } else {
    const ratio = Math.min(1, Math.max(0, (ageMin - greenBelowMin) / (redAtMin - greenBelowMin)));
    if (ratio < 0.5) { bg = 'bg-amber-900/40'; fg = 'text-amber-300'; }
    else { bg = 'bg-orange-900/50'; fg = 'text-orange-300'; }
  }

  const fmt = ageMin < 1 ? '<1m'
            : ageMin < 60 ? `${Math.round(ageMin)}m`
            : ageMin < 60 * 24 ? `${Math.round(ageMin / 60)}h`
            : `${Math.round(ageMin / (60 * 24))}d`;

  const tooltip = `${label ? label + ': ' : ''}last poll ${new Date(t).toLocaleString()}`;

  return (
    <span className={`inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] ${bg} ${fg} ${flash ? 'animate-pulse' : ''}`} title={tooltip}>
      <Clock size={10} /> {fmt}
    </span>
  );
}
