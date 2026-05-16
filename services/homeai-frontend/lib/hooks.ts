'use client';

import { useQuery } from '@tanstack/react-query';

export function useSlug<T = unknown>(slug: string, params: Record<string, string | number> = {}, options: { refetchInterval?: number } = {}) {
  const qs = new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)])).toString();
  return useQuery<T[]>({
    queryKey: ['slug', slug, qs],
    queryFn: async () => {
      const r = await fetch(`/api/slug/${slug}${qs ? '?' + qs : ''}`);
      if (!r.ok) throw new Error(`slug ${slug} ${r.status}`);
      return r.json();
    },
    refetchInterval: options.refetchInterval,
  });
}
