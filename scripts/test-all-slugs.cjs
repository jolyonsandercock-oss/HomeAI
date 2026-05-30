#!/usr/bin/env node
/*
 * test-all-slugs.cjs — smoke-test every whitelisted DB slug.
 *
 * Runs INSIDE the frontend container so it reuses the exact production path:
 * the same `pg` client, the `homeai_readonly` role (POSTGRES_READONLY_URL),
 * the same :named-param binding, and `home_ai.set_realm()` for RLS.
 *
 * Run:
 *   docker exec -i homeai-frontend node - < scripts/test-all-slugs.cjs
 *   docker exec -i homeai-frontend node - < scripts/test-all-slugs.cjs sales   # filter by substring
 *
 * For each active + approved slug it binds synthetic params (defaults from the
 * param_schema where given, else a type-appropriate value for required params,
 * else null for optionals) and executes the SQL under the slug's OWN realm.
 *
 * NB on realm: the Next.js /app HTTP path always runs as realm='work', so it
 * cannot reach owner-realm slugs (they 400 "refusing to serve"). To actually
 * exercise their SQL this harness sets each slug's own realm — so a PASS here
 * means the SQL is valid, not that the slug is reachable from the work-realm UI.
 * `shared` is not a settable realm (set_realm accepts owner|work|personal); like
 * the UI, shared slugs are run here under the caller realm 'work'.
 *
 * Exit 0 = all slugs ran; exit 1 = one or more threw.
 */
'use strict';

const { Pool } = require('pg');

const FILTER = process.argv[2] || '';
const TODAY = new Date().toISOString().slice(0, 10);

// Mirror of lib/db.ts bindNamedParams — :name -> $1,$2 in source order,
// leaving ::casts alone. Keep in sync if the app's version changes.
const NAMED_PARAM_RE = /(?<!:):([a-zA-Z_][a-zA-Z0-9_]*)/g;
function bindNamedParams(sql, params) {
  const seen = [];
  const out = sql.replace(NAMED_PARAM_RE, (_m, name) => {
    if (!seen.includes(name)) seen.push(name);
    return `$${seen.indexOf(name) + 1}`;
  });
  const args = seen.map((n) => (n in params ? params[n] : null));
  return { sql: out, args };
}

// Build a params object from a slug's param_schema. Strategy:
//   - spec has `default`        -> use it (what a sensible caller sends)
//   - spec required (or neither optional nor default) -> synthesise by type
//   - otherwise (pure optional) -> omit, so it binds to null (UI calls these
//     param-less, so the SQL must COALESCE; if it doesn't, that's a real bug)
function buildParams(schema) {
  const params = {};
  for (const [key, spec] of Object.entries(schema || {})) {
    if (spec && Object.prototype.hasOwnProperty.call(spec, 'default')) {
      params[key] = spec.default;
      continue;
    }
    const required = spec && (spec.required === true || (!spec.optional && spec.default === undefined && spec.required === undefined));
    if (!required) continue;
    if (spec.format === 'date') params[key] = TODAY;
    else if (spec.type === 'int') params[key] = spec.min ?? 1;
    else params[key] = 'x';
  }
  return params;
}

async function main() {
  const cs = process.env.POSTGRES_READONLY_URL;
  if (!cs) {
    console.error('POSTGRES_READONLY_URL not set — run this inside homeai-frontend.');
    process.exit(2);
  }
  const pool = new Pool({ connectionString: cs, max: 4, idleTimeoutMillis: 10_000 });

  const { rows: slugs } = await pool.query(
    `SELECT slug, realm, param_schema, sql_template
       FROM query_whitelist
      WHERE active = true AND approved_at IS NOT NULL
      ORDER BY slug`
  );

  const tested = slugs.filter((s) => !FILTER || s.slug.includes(FILTER));
  const failures = [];
  const byRealm = {};
  let passed = 0;

  for (const s of tested) {
    byRealm[s.realm] = byRealm[s.realm] || { pass: 0, fail: 0 };
    const params = buildParams(s.param_schema);
    const { sql, args } = bindNamedParams(s.sql_template, params);
    // shared slugs aren't a settable realm; run them under the caller realm
    // 'work' exactly as the /app UI does. owner/work/personal run as themselves.
    const reqRealm = s.realm === 'shared' ? 'work' : s.realm;
    const client = await pool.connect();
    const started = Date.now();
    try {
      await client.query("SET statement_timeout = '15s'");
      await client.query('SELECT home_ai.set_realm($1)', [reqRealm]);
      const r = await client.query(sql, args);
      const ms = Date.now() - started;
      passed++;
      byRealm[s.realm].pass++;
      if (process.env.VERBOSE) console.log(`  ok   ${s.slug.padEnd(38)} ${String(r.rowCount).padStart(5)} rows  ${ms}ms`);
    } catch (e) {
      byRealm[s.realm].fail++;
      failures.push({ slug: s.slug, realm: s.realm, args, error: e.message.replace(/\s+/g, ' ').trim() });
    } finally {
      client.release();
    }
  }

  await pool.end();

  console.log('');
  if (failures.length) {
    console.log(`FAILURES (${failures.length}):`);
    for (const f of failures) {
      console.log(`  ✗ ${f.slug}  [realm=${f.realm}]  args=${JSON.stringify(f.args)}`);
      console.log(`      ${f.error}`);
    }
    console.log('');
  }
  const realmLine = Object.entries(byRealm)
    .map(([r, c]) => `${r}: ${c.pass}/${c.pass + c.fail}`)
    .join('   ');
  console.log(`Slugs tested: ${tested.length}   passed: ${passed}   failed: ${failures.length}`);
  console.log(`By realm:     ${realmLine}`);
  process.exit(failures.length ? 1 : 0);
}

main().catch((e) => {
  console.error('harness crashed:', e);
  process.exit(2);
});
