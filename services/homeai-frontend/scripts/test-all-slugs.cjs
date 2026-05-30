// One-off slug smoke test. Mirrors lib/db.ts runSlugDirect binding.
// Runs every active+approved slug with safe default params under a 15s timeout.
// Read-only: connects with POSTGRES_READONLY_URL. PASS = executes without error.
const { Pool } = require("pg");
const fs = require("fs");

const today = new Date().toISOString().slice(0, 10);
const DEFAULTS = {
  range: "7d", site: "all", days: 7, n_days: 7, window_days: 30, window: 30,
  months: 3, weeks: 4, limit: 50, lim: 50, top_n: 10,
  date: today, target_date: today, day: today, as_of: today,
  start_date: "2026-01-01", end_date: today, from_date: "2026-01-01", to_date: today,
  account: "admin", realm: "work", entity_id: "1", entity: "1", site_slug: "malthouse",
  source: "malthouse", token: "test", id: "1", category: "FOOD SALES",
  vendor: "test", capability: "classification", room_type: "double",
};
const NAMED_PARAM_RE = /(?<!:):([a-zA-Z_][a-zA-Z0-9_]*)/g;

function bind(template) {
  const seen = [];
  const text = template.replace(NAMED_PARAM_RE, (_m, name) => {
    if (!seen.includes(name)) seen.push(name);
    return `$${seen.indexOf(name) + 1}`;
  });
  const values = seen.map((n) => (DEFAULTS[n] !== undefined ? DEFAULTS[n] : null));
  return { text, values, names: seen };
}

async function main() {
  const cs = process.env.POSTGRES_READONLY_URL;
  if (!cs) throw new Error("POSTGRES_READONLY_URL not set");
  const pool = new Pool({ connectionString: cs, max: 4 });
  const { rows: slugs } = await pool.query(
    `SELECT slug, sql_template, realm FROM query_whitelist
     WHERE active = true AND approved_at IS NOT NULL ORDER BY slug`
  );
  const results = [];
  for (const def of slugs) {
    const { text, values, names } = bind(def.sql_template);
    const client = await pool.connect();
    let status = "PASS", detail = "", rowcount = 0;
    try {
      await client.query("SET statement_timeout = '15s'");
      try { await client.query(`SELECT home_ai.set_realm($1)`, ["work"]); } catch (_) {}
      const r = await client.query(text, values);
      rowcount = r.rowCount;
    } catch (e) {
      const msg = (e.message || "").split("\n")[0];
      status = /statement timeout|canceling/i.test(msg) ? "TIMEOUT" : "FAIL";
      detail = msg.slice(0, 180);
    } finally {
      client.release();
    }
    results.push({ slug: def.slug, realm: def.realm, status, rowcount, params: names, detail });
  }
  await pool.end();

  const by = (s) => results.filter((r) => r.status === s);
  const pass = by("PASS"), fail = by("FAIL"), to = by("TIMEOUT");
  console.log(`\n=== SLUG TEST: ${results.length} total | ${pass.length} PASS | ${fail.length} FAIL | ${to.length} TIMEOUT ===\n`);
  if (fail.length || to.length) {
    console.log("--- PROBLEMS ---");
    for (const r of [...fail, ...to]) {
      console.log(`[${r.status}] ${r.slug} (realm=${r.realm}) params=[${r.params.join(",")}]\n        ${r.detail}`);
    }
    console.log("");
  }
  const empties = pass.filter((r) => r.rowcount === 0);
  console.log(`--- PASS-but-EMPTY (${empties.length}) [usually fine: param/realm-gated] ---`);
  console.log(empties.map((r) => r.slug).join(", "));
  fs.writeFileSync("/tmp/slug-results.json", JSON.stringify(results, null, 2));
  console.log(`\nFull JSON written to /tmp/slug-results.json inside container`);
}
main().catch((e) => { console.error("HARNESS ERROR:", e.message); process.exit(1); });
