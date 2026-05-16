'use client';

import { createContext, useContext, useState, useCallback } from 'react';

interface EditModeState {
  editing: boolean;
  toggle: () => void;
}

const Ctx = createContext<EditModeState>({ editing: false, toggle: () => {} });

export function EditModeProvider({ children }: { children: React.ReactNode }) {
  const [editing, setEditing] = useState(false);
  const toggle = useCallback(() => setEditing((v) => !v), []);
  return <Ctx.Provider value={{ editing, toggle }}>{children}</Ctx.Provider>;
}

export function useEditMode() {
  return useContext(Ctx);
}
