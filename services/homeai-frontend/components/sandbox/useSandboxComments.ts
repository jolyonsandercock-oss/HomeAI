'use client';

import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';

export interface SandboxComment {
  id: number;
  component_id: string;
  comment_text: string;
  author: string | null;
  page_path: string | null;
  created_at: string;
  resolved_at: string | null;
}

export function useSandboxComments(componentId: string) {
  const qc = useQueryClient();
  const q = useQuery<SandboxComment[]>({
    queryKey: ['sandbox.comments', componentId],
    queryFn: async () => {
      const r = await fetch(`/api/sandbox/comments?component_id=${encodeURIComponent(componentId)}`);
      if (!r.ok) throw new Error('fetch failed');
      return r.json();
    },
  });
  const addComment = useMutation({
    mutationFn: async (text: string) => {
      const r = await fetch('/api/sandbox/comments', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          component_id: componentId,
          comment_text: text,
          page_path: typeof window !== 'undefined' ? window.location.pathname : null,
        }),
      });
      if (!r.ok) throw new Error('save failed');
      return r.json();
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['sandbox.comments', componentId] }),
  });
  return { comments: q.data ?? [], isLoading: q.isLoading, addComment: addComment.mutateAsync };
}
