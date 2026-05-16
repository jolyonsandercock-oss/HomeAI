import { Pool } from 'pg';

declare global {
  // eslint-disable-next-line no-var
  var _pgPool: Pool | undefined;
}

export function pool(): Pool {
  if (!global._pgPool) {
    const cs = process.env.POSTGRES_READONLY_URL;
    if (!cs) throw new Error('POSTGRES_READONLY_URL not set');
    global._pgPool = new Pool({
      connectionString: cs,
      max: 4,
      idleTimeoutMillis: 30_000,
    });
  }
  return global._pgPool;
}

export async function withRealm<T>(realm: string, fn: () => Promise<T>): Promise<T> {
  const client = await pool().connect();
  try {
    await client.query(`SELECT home_ai.set_realm($1)`, [realm]);
    return await fn();
  } finally {
    client.release();
  }
}

export async function runSlug(slug: string, params: Record<string, unknown> = {}): Promise<unknown[]> {
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
  // Run with realm = owner (server-side, never trust client header)
  const client = await p.connect();
  try {
    await client.query(`SELECT home_ai.set_realm('owner')`);
    const r = await client.query(sql_template, args);
    return r.rows;
  } finally {
    client.release();
  }
}
