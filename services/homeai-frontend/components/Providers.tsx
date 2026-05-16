'use client';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';
import { EditModeProvider } from '@/components/sandbox/EditModeContext';

export function Providers({ children }: { children: React.ReactNode }) {
  const [qc] = useState(() => new QueryClient({
    defaultOptions: { queries: { staleTime: 60_000, refetchOnWindowFocus: false } },
  }));
  return (
    <QueryClientProvider client={qc}>
      <EditModeProvider>{children}</EditModeProvider>
    </QueryClientProvider>
  );
}
