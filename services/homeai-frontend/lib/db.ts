import { Pool } from 'pg';

declare global {
  // eslint-disable-next-line no-var
  var _pgPool: Pool | undefined;
}

// Three runtime modes:
//   (1) HOMEAI_DATA_URL set       — Vercel + others: HTTPS proxy via Tailscale Funnel
//   (2) POSTGRES_READONLY_URL set — direct DB (local container, dev)
//   (3) neither                    — error
const PROXY_URL   = process.env.HOMEAI_DATA_URL;
const PROXY_TOKEN = process.env.HOMEAI_DATA_TOKEN;

export function pool(): Pool {
  if (!global._pgPool) {
    const cs = process.env.POSTGRES_READONLY_URL;
    if (!cs) throw new Error('POSTGRES_READONLY_URL not set (and HOMEAI_DATA_URL not set)');
    global._pgPool = new Pool({
      connectionString: cs,
      max: 4,
      idleTimeoutMillis: 30_000,
    });
  }
  return global._pgPool;
}

async function fetchWithRetry(url: string, init: RequestInit, attempts = 3, timeoutMs = 20000): Promise<Response> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), timeoutMs);
    try {
      const r = await fetch(url, { ...init, signal: ctl.signal, cache: 'no-store' });
      clearTimeout(t);
      // Retry on 502/503/504 (likely transient relay issues)
      if (r.status >= 502 && r.status <= 504 && i < attempts - 1) {
        await new Promise((res) => setTimeout(res, 500 * (i + 1)));
        continue;
      }
      return r;
    } catch (e) {
      clearTimeout(t);
      lastErr = e;
      if (i < attempts - 1) await new Promise((res) => setTimeout(res, 500 * (i + 1)));
    }
  }
  throw lastErr ?? new Error('fetch retries exhausted');
}

async function runSlugViaProxy(slug: string, params: Record<string, unknown>): Promise<unknown[]> {
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== null && v !== undefined) qs.set(k, String(v));
  }
  const url = `${PROXY_URL}/slug/${slug}${qs.toString() ? `?${qs.toString()}` : ''}`;
  const r = await fetchWithRetry(url, {
    headers: { 'Authorization': `Bearer ${PROXY_TOKEN ?? ''}` },
  });
  if (!r.ok) throw new Error(`data-proxy ${slug} ${r.status}`);
  return r.json();
}

async function runSlugDirect(slug: string, params: Record<string, unknown>): Promise<unknown[]> {
  const p = pool();
  const def = await p.query(
    'SELECT sql_template, param_schema FROM query_whitelist WHERE slug = $1 AND active = true AND approved_at IS NOT NULL',
    [slug]
  );
  if (def.rowCount === 0) throw new Error(`slug not found: ${slug}`);
  const { sql_template, param_schema } = def.rows[0];
  const ps = param_schema && typeof param_schema === 'string'
    ? JSON.parse(param_schema)
    : (param_schema || {});
  const args = Object.keys(ps).map((k) => (params as Record<string, unknown>)[k] ?? null);
  const client = await p.connect();
  try {
    await client.query(`SELECT home_ai.set_realm('owner')`);
    const r = await client.query(sql_template, args);
    return r.rows;
  } finally {
    client.release();
  }
}

export async function runSlug(slug: string, params: Record<string, unknown> = {}): Promise<unknown[]> {
  if (PROXY_URL) return runSlugViaProxy(slug, params);
  return runSlugDirect(slug, params);
}

export interface SandboxCommentPost {
  component_id: string; comment_text: string;
  page_path?: string | null; author?: string | null;
}
export async function postSandboxComment(body: SandboxCommentPost) {
  if (PROXY_URL) {
    const r = await fetch(`${PROXY_URL}/sandbox/comments`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${PROXY_TOKEN ?? ''}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });
    if (!r.ok) throw new Error(`proxy sandbox POST ${r.status}`);
    return r.json();
  }
  const p = pool();
  const r = await p.query(
    `INSERT INTO sandbox_comments (component_id, comment_text, author, page_path)
     VALUES ($1, $2, $3, $4) RETURNING id, created_at`,
    [body.component_id, body.comment_text, body.author ?? null, body.page_path ?? null]
  );
  return r.rows[0];
}

export async function getSandboxComments(componentId?: string, pagePath?: string) {
  if (PROXY_URL) {
    const qs = new URLSearchParams();
    if (componentId) qs.set('component_id', componentId);
    if (pagePath)    qs.set('page_path', pagePath);
    const r = await fetch(`${PROXY_URL}/sandbox/comments${qs.toString() ? `?${qs}` : ''}`, {
      headers: { 'Authorization': `Bearer ${PROXY_TOKEN ?? ''}` },
      cache: 'no-store',
    });
    if (!r.ok) throw new Error(`proxy sandbox GET ${r.status}`);
    return r.json();
  }
  const where: string[] = [];
  const args: (string | null)[] = [];
  if (componentId) { args.push(componentId); where.push(`component_id = $${args.length}`); }
  if (pagePath)    { args.push(pagePath);    where.push(`page_path = $${args.length}`); }
  const sql = `SELECT id, component_id, comment_text, author, page_path, created_at, resolved_at FROM sandbox_comments ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY created_at DESC LIMIT 100`;
  const r = await pool().query(sql, args);
  return r.rows;
}

export async function healthCheck() {
  if (PROXY_URL) {
    const r = await fetchWithRetry(`${PROXY_URL}/healthz`, {});
    if (!r.ok) throw new Error(`proxy /healthz ${r.status}`);
    return r.json();
  }
  const r = await pool().query('SELECT NOW() AS now');
  return { status: 'ok', db_time: r.rows[0].now };
}
