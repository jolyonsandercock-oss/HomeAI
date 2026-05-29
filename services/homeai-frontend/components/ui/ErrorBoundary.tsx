'use client';

// Hermes D3: app-level error boundary. Catches render errors in any child
// tree, shows a contextual message + reload button instead of a blank
// white screen. Console-logs the error so it's visible in production logs.

import React from 'react';

interface State {
  error: Error | null;
}

export class ErrorBoundary extends React.Component<
  { children: React.ReactNode; fallback?: React.ReactNode },
  State
> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    // eslint-disable-next-line no-console
    console.error('[Home AI] render error:', error, info);
  }

  render() {
    if (this.state.error) {
      if (this.props.fallback) return this.props.fallback;
      return (
        <div
          role="alert"
          className="m-4 rounded border border-red-600 bg-red-950/40 px-4 py-3 text-sm text-red-200"
        >
          <strong className="block text-red-300 text-base mb-1">
            ⚠ Something went wrong
          </strong>
          <p className="mb-2">
            This section failed to render. The error has been logged. You can try reloading
            the page; if the problem persists, the underlying data slug may be down.
          </p>
          <pre className="text-xs overflow-x-auto opacity-70 mt-2">
            {this.state.error.message}
          </pre>
          <button
            onClick={() => location.reload()}
            className="mt-3 inline-flex items-center gap-1 px-3 py-1.5 rounded bg-amber-500 text-ink-0 text-xs font-medium hover:bg-amber-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-300"
          >
            Reload page
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}
