import { NextRequest, NextResponse } from 'next/server';

// H6 / review A5 — best-effort in-memory rate limiter on write requests.
// Fixed 60s window, 10 writes/min/IP. Process-local (standalone single instance);
// it is a guardrail against runaway/abusive clients, not a distributed quota.
const WINDOW_MS = 60_000;
const MAX_WRITES = 10;
const WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

type Bucket = { count: number; windowStart: number };
const buckets = new Map<string, Bucket>();

function clientIp(req: NextRequest): string {
  const fwd = req.headers.get('x-forwarded-for');
  if (fwd) return fwd.split(',')[0].trim();
  return req.headers.get('x-real-ip') || '0.0.0.0';
}

export function middleware(req: NextRequest) {
  if (!WRITE_METHODS.has(req.method)) return NextResponse.next();

  const ip = clientIp(req);
  const now = Date.now();
  const b = buckets.get(ip);

  if (!b || now - b.windowStart >= WINDOW_MS) {
    buckets.set(ip, { count: 1, windowStart: now });
    // Opportunistic cleanup so the map can't grow unbounded.
    if (buckets.size > 5000) {
      for (const [k, v] of buckets) {
        if (now - v.windowStart >= WINDOW_MS) buckets.delete(k);
      }
    }
    return NextResponse.next();
  }

  if (b.count >= MAX_WRITES) {
    const retryAfter = Math.ceil((b.windowStart + WINDOW_MS - now) / 1000);
    return NextResponse.json(
      { error: 'rate limited', retry_after_seconds: retryAfter },
      { status: 429, headers: { 'Retry-After': String(retryAfter) } },
    );
  }

  b.count += 1;
  return NextResponse.next();
}

export const config = {
  matcher: ['/api/:path*'],
};
