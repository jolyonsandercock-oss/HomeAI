'use client';

export function SparkLine({ values, colour = '#f59e0b' }: { values: number[]; colour?: string }) {
  if (!values || values.length < 2) return null;
  const n = values.length;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = max - min || 1;
  const pts = values.map((v, i) => {
    const x = (i / (n - 1)) * 100;
    const y = 100 - ((v - min) / range) * 100;
    return `${x.toFixed(2)},${y.toFixed(2)}`;
  }).join(' ');
  return (
    <svg viewBox="0 0 100 100" preserveAspectRatio="none" className="w-full h-full">
      <polyline fill="none" stroke={colour} strokeWidth="2" points={pts} vectorEffect="non-scaling-stroke" />
    </svg>
  );
}
