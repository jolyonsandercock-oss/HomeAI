'use client';

/**
 * U189 — Occupancy heatmap: room × day grid.
 *
 * 12-ish rooms × 28 days. Cell colour: filled (booked) / empty (available).
 * Optional rate intensity by amber lightness.
 */
interface HeatmapRow {
  room: string;
  night: string;
  occupied: boolean;
  rate: number | null;
}

export function OccupancyHeatmap({ rows }: { rows: HeatmapRow[] }) {
  if (!rows || rows.length === 0) return <div className="text-ink-500 text-sm">No occupancy data.</div>;

  const rooms = Array.from(new Set(rows.map(r => r.room))).sort();
  const days = Array.from(new Set(rows.map(r => r.night))).sort();

  // Index for lookup
  const lookup: Record<string, HeatmapRow> = {};
  rows.forEach(r => { lookup[`${r.room}|${r.night}`] = r; });

  // Rate colour scale
  const rates = rows.filter(r => r.rate).map(r => Number(r.rate));
  const rateMax = rates.length ? Math.max(...rates) : 0;

  return (
    <div className="overflow-x-auto">
      <table className="text-xs border-collapse">
        <thead>
          <tr>
            <th className="text-left px-1 sticky left-0 bg-ink-50">room</th>
            {days.map(d => {
              const dd = new Date(d);
              const isWeekend = [0, 6].includes(dd.getDay());
              return (
                <th key={d} className={'px-0.5 ' + (isWeekend ? 'text-amber-500' : 'text-ink-500')}>
                  {dd.toLocaleDateString('en-GB', { day: '2-digit' })}
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {rooms.map(room => (
            <tr key={room}>
              <td className="px-1 text-ink-700 font-mono sticky left-0 bg-ink-50">{room}</td>
              {days.map(d => {
                const r = lookup[`${room}|${d}`];
                const occupied = r?.occupied;
                const rate = r?.rate ? Number(r.rate) : 0;
                const intensity = rateMax > 0 && occupied ? rate / rateMax : 0;
                const bg = occupied
                  ? `rgba(245, 158, 11, ${0.3 + intensity * 0.6})`
                  : 'rgba(31, 31, 31, 1)';
                return (
                  <td
                    key={d}
                    className="w-3 h-4"
                    style={{ background: bg }}
                    title={`${room} ${d}: ${occupied ? `£${rate.toFixed(0)}` : 'available'}`}
                  />
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
