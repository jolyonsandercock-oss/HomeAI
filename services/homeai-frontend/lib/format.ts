export function gbp(n: number | string | null | undefined, decimals = 0): string {
  if (n === null || n === undefined) return '—';
  const num = typeof n === 'string' ? parseFloat(n) : n;
  if (!Number.isFinite(num)) return '—';
  return '£' + num.toLocaleString('en-GB', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

export function ordinal(n: number): string {
  if (n >= 11 && n <= 13) return `${n}th`;
  const s = ['th', 'st', 'nd', 'rd'];
  return `${n}${s[(n % 10) > 3 ? 0 : (n % 10)]}`;
}

export function fmtDay(d: string | Date): string {
  const dt = typeof d === 'string' ? new Date(d) : d;
  const day = dt.toLocaleDateString('en-GB', { weekday: 'short' });
  return `${day} ${ordinal(dt.getDate())}`;
}

/** Normalise caterbook room labels for the dashboard.
 *  "Room 6 - Double Room"            → "R6"
 *  "Rm8"                              → "R8"
 *  "View on Airbnb Room 4 - Single"   → "R4"
 *  "View on Airbnb The Flat"          → "The Flat"
 *  "Garden Suite"                     → "Garden Suite"
 *  "" / null                          → "—" */
export function formatRoom(raw: string | null | undefined): string {
  if (!raw) return '—';
  let s = String(raw).trim();
  s = s.replace(/^View on\s+(Airbnb|Agoda|Booking\.com|Booking|Expedia|Hotels?\.com)\s*/i, '');
  const numMatch = s.match(/^(?:Room|Rm)\s*(\d+)/i);
  if (numMatch) return `R${numMatch[1]}`;
  return s.replace(/\s*-\s*.*$/, '').trim() || s;
}
