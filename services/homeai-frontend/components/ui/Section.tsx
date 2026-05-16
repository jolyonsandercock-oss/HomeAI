'use client';

export function Section({ title, action, children }: { title: string; action?: React.ReactNode; children: React.ReactNode }) {
  return (
    <section className="mb-6">
      <header className="flex items-center justify-between mb-2">
        <h2 className="text-xs uppercase tracking-wider text-ink-500 font-medium">{title}</h2>
        {action}
      </header>
      {children}
    </section>
  );
}
