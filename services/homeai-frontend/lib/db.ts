import { Pool, PoolClient } from 'pg';

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

// Translate :named params into $1, $2, ... in source order. Mirrors the
// build-dashboard FastAPI slug runner so slug SQL is portable between
// both consumers. Lookbehind ensures `::cast` syntax is left alone.
const NAMED_PARAM_RE = /(?<!:):([a-zA-Z_][a-zA-Z0-9_]*)/g;
function bindNamedParams(sql: string, params: Record<string, unknown>): { sql: string; args: unknown[] } {
  const seen: string[] = [];
  const out = sql.replace(NAMED_PARAM_RE, (_m, name: string) => {
    if (!seen.includes(name)) seen.push(name);
    return `$${seen.indexOf(name) + 1}`;
  });
  const args = seen.map(n => (params as Record<string, unknown>)[n] ?? null);
  return { sql: out, args };
}

// Realm of the calling page. Default = 'work' for the Next.js mirror at
// /app/*. The future /app/private/* surface will pass a different realm
// via the runSlug call; until that exists, owner-realm slugs are denied.
const DEFAULT_REQUEST_REALM = 'work';

// Run queries with app.current_realm pinned for the WHOLE transaction.
// home_ai.set_realm uses set_config(..., is_local=true) — i.e. SET LOCAL,
// scoped to the surrounding transaction. It MUST therefore share one
// transaction with the dependent queries; otherwise each statement is its own
// autocommit txn, the realm evaporates before the data query runs, and the RLS
// realm_isolation policy falls back to its NULL/'' -> all-realms branch (U147
// Bug A — the cause of cross-realm leakage on the read path). Wrapping here is
// pool-safe: COMMIT/ROLLBACK clears the LOCAL setting for the next borrower.
async function withRealm<T>(realm: string, fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool().connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT home_ai.set_realm($1)', [realm]);
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    try { await client.query('ROLLBACK'); } catch { /* already aborted */ }
    throw e;
  } finally {
    client.release();
  }
}

async function runSlugDirect(slug: string, params: Record<string, unknown>, realm: string): Promise<unknown[]> {
  const p = pool();
  const def = await p.query(
    'SELECT sql_template, param_schema, realm FROM query_whitelist WHERE slug = $1 AND active = true AND approved_at IS NOT NULL',
    [slug]
  );
  if (def.rowCount === 0) throw new Error(`slug not found: ${slug}`);
  const { sql_template, realm: slug_realm } = def.rows[0];
  if (slug_realm !== realm && slug_realm !== 'shared') {
    throw new Error(`slug ${slug} is realm=${slug_realm}; refusing to serve to realm=${realm}`);
  }
  const { sql, args } = bindNamedParams(sql_template, params);
  return withRealm(realm, async (client) => {
    const r = await client.query(sql, args);
    return r.rows;
  });
}

export async function runSlug(slug: string, params: Record<string, unknown> = {}, realm: string = DEFAULT_REQUEST_REALM): Promise<unknown[]> {
  if (PROXY_URL) return runSlugViaProxy(slug, params);
  return runSlugDirect(slug, params, realm);
}

// Invoices exception workflow — confirm or categorise a purchase (the latter
// applies across the vendor). Write happens inside the SECURITY DEFINER
// home_ai.verify_purchase fn, so the readonly role only needs EXECUTE.
export async function verifyPurchase(body: { purchase_id: number; action: 'confirm' | 'categorise'; category?: string | null }) {
  return withRealm('work', async (client) => {
    const r = await client.query(
      `SELECT home_ai.verify_purchase($1, $2, $3) AS affected`,
      [body.purchase_id, body.action, body.category ?? null]
    );
    return { ok: true, affected: r.rows[0]?.affected ?? 0 };
  });
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

// Cash-up write endpoints (U135 T6)
export interface CashupInput {
  site: 'malthouse' | 'sandwich';
  cashup_date: string;
  till_id: string;
  cash_taken_pence?: number | null;
  caterpay_pence?: number | null;
  collins_deposit_pence?: number | null;
  manual_notes?: string | null;
  entered_by?: string | null;
}

export async function upsertCashupInput(body: CashupInput) {
  return withRealm('work', async (client) => {
    const r = await client.query(
      `INSERT INTO cashup_inputs (site, cashup_date, till_id, cash_taken_pence,
                                  caterpay_pence, collins_deposit_pence,
                                  manual_notes, entered_by)
       VALUES ($1, $2::date, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (site, cashup_date, till_id) DO UPDATE
          SET cash_taken_pence      = EXCLUDED.cash_taken_pence,
              caterpay_pence        = EXCLUDED.caterpay_pence,
              collins_deposit_pence = EXCLUDED.collins_deposit_pence,
              manual_notes          = EXCLUDED.manual_notes,
              entered_by            = EXCLUDED.entered_by,
              entered_at            = NOW()
       RETURNING id, entered_at`,
      [body.site, body.cashup_date, body.till_id,
       body.cash_taken_pence ?? null, body.caterpay_pence ?? null,
       body.collins_deposit_pence ?? null, body.manual_notes ?? null,
       body.entered_by ?? null]
    );
    return r.rows[0];
  });
}

export interface SafeMovement {
  movement_date: string;
  site: 'malthouse' | 'sandwich';
  direction: 'to_safe' | 'from_safe';
  amount_pence: number;
  notes?: string | null;
  entered_by?: string | null;
}

export async function insertSafeMovement(body: SafeMovement) {
  return withRealm('work', async (client) => {
    const r = await client.query(
      `INSERT INTO safe_movements (movement_date, site, direction, amount_pence, notes, entered_by)
       VALUES ($1::date, $2, $3, $4, $5, $6)
       RETURNING id, entered_at`,
      [body.movement_date, body.site, body.direction, body.amount_pence,
       body.notes ?? null, body.entered_by ?? null]
    );
    return r.rows[0];
  });
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
