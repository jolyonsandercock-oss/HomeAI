/// <reference types="node" />
// /app/api/scrape/trigger/route.ts
// Fire-and-forget trigger for TouchOffice scrape + bridge.
// Returns immediately; scrape runs in background on playwright container.

import { NextResponse } from 'next/server';
import * as http from 'http';

export const dynamic = 'force-dynamic';

function fire(url: string): void {
  try {
    const req = http.request(url, { method: 'POST', timeout: 3000 }, () => {});
    req.on('error', () => {});  // swallow — fire-and-forget
    req.on('timeout', () => { req.destroy(); });
    req.end();
  } catch { /* ignore */ }
}

export async function POST() {
  // Fire scrape for both sites (fire-and-forget — can't wait for browser)
  fire('http://homeai-playwright:8001/ingest/touchoffice?site=malthouse');
  fire('http://homeai-playwright:8001/ingest/touchoffice?site=sandwich');

  // Return immediately — the frontend refetches the poll clock in ~60s
  return NextResponse.json({ success: true, note: 'scrape triggered (background)' });
}
