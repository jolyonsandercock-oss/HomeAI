'use client';

import { useState } from 'react';
import { MessageCircle, GripVertical } from 'lucide-react';
import { useEditMode } from './EditModeContext';
import { useSandboxComments } from './useSandboxComments';

interface SandboxWrapperProps {
  id: string;
  label?: string;
  children: React.ReactNode;
}

export function SandboxWrapper({ id, label, children }: SandboxWrapperProps) {
  const { editing } = useEditMode();
  const [panelOpen, setPanelOpen] = useState(false);
  const [draft, setDraft] = useState('');
  const { comments, addComment } = useSandboxComments(id);

  if (!editing) {
    return <div className="sandbox-target" data-sandbox-id={id}>{children}</div>;
  }

  return (
    <div className="sandbox-target relative group" data-sandbox-id={id}>
      <div className="absolute -top-2 -left-2 flex items-center gap-1 px-1.5 py-0.5 bg-amber-500 text-ink-0 text-xs font-mono rounded shadow z-10">
        <GripVertical size={10} />
        {label ?? id}
        <button
          onClick={() => setPanelOpen((v) => !v)}
          className="flex items-center gap-0.5 ml-1 hover:opacity-80"
        >
          <MessageCircle size={10} />
          {comments.length > 0 && <span>{comments.length}</span>}
        </button>
      </div>
      {children}
      {panelOpen && (
        <div className="absolute z-20 top-full mt-2 left-0 right-0 sm:left-auto sm:w-80 bg-ink-100 border border-ink-200 rounded-lg p-3 shadow-xl">
          <div className="text-xs uppercase tracking-wider text-ink-500 mb-2">
            Comments — {id}
          </div>
          <div className="space-y-2 max-h-48 overflow-y-auto">
            {comments.length === 0 && (
              <div className="text-xs text-ink-500 italic">No comments yet.</div>
            )}
            {comments.map((c) => (
              <div key={c.id} className="text-xs">
                <div className="text-ink-700">{c.comment_text}</div>
                <div className="text-xs text-ink-500 mt-0.5">
                  {c.author ?? 'anon'} · {new Date(c.created_at).toLocaleString('en-GB')}
                </div>
              </div>
            ))}
          </div>
          <div className="mt-3 flex gap-2">
            <input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder="Add a comment…"
              className="flex-1 bg-ink-0 border border-ink-200 rounded px-2 py-1 text-xs text-ink-800 placeholder:text-ink-500 focus:outline-none focus:border-amber-500"
            />
            <button
              onClick={async () => {
                if (!draft.trim()) return;
                await addComment(draft.trim());
                setDraft('');
              }}
              className="px-2.5 py-1 bg-amber-500 text-ink-0 text-xs rounded font-medium hover:bg-amber-400"
            >Save</button>
          </div>
        </div>
      )}
    </div>
  );
}
