'use client';

/**
 * U188 — Tide curve sparkline.
 *
 * Takes high/low tide times for one day and renders a smooth sine-like
 * curve so "low at 14:00, high at 21:00" reads in 1 second.
 */
interface TideEvent {
  high_low: 'high' | 'low';
  tide_time: string;  // HH:MM:SS or HH:MM
}

export function TideCurve({ tides, width = 120, height = 24 }: { tides: TideEvent[]; width?: number; height?: number }) {
  if (!tides || tides.length === 0) return null;

  // Convert each tide event to a (x, y) where x = minute-of-day / 1440 and
  // y = -1 (low) or +1 (high).
  const knots = tides.map(t => {
    const [hh, mm] = (t.tide_time || '00:00').split(':').map(Number);
    return {
      x: (hh * 60 + (mm || 0)) / 1440,
      y: t.high_low === 'high' ? 1 : -1,
    };
  }).sort((a, b) => a.x - b.x);

  if (knots.length < 2) return null;

  // Render a smooth path between knots using a sine interpolation
  const PTS = 50;
  const path: string[] = [];
  for (let i = 0; i < PTS; i++) {
    const x = i / (PTS - 1);
    // Find surrounding knots
    let prev = knots[0], next = knots[knots.length - 1];
    for (let j = 0; j < knots.length - 1; j++) {
      if (knots[j].x <= x && knots[j + 1].x >= x) {
        prev = knots[j]; next = knots[j + 1]; break;
      }
    }
    if (x < knots[0].x) { prev = knots[knots.length - 1]; next = knots[0]; }
    if (x > knots[knots.length - 1].x) { prev = knots[knots.length - 1]; next = knots[0]; }
    const dx = (next.x - prev.x) || 1;
    const t = (x - prev.x) / dx;
    // Cosine interpolation gives the wave shape
    const y_t = (prev.y + next.y) / 2 + (prev.y - next.y) / 2 * Math.cos(t * Math.PI);
    const px = x * width;
    const py = height / 2 - (y_t * (height / 2 - 1));
    path.push(`${px.toFixed(1)},${py.toFixed(1)}`);
  }

  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
      <polyline
        fill="none" stroke="#3b82f6" strokeWidth="1.5"
        points={path.join(' ')} vectorEffect="non-scaling-stroke"
      />
      {knots.map((k, i) => (
        <circle
          key={i}
          cx={k.x * width}
          cy={height / 2 - k.y * (height / 2 - 1)}
          r={1.5}
          fill={k.y > 0 ? '#3b82f6' : '#a3a3a3'}
        />
      ))}
    </svg>
  );
}
