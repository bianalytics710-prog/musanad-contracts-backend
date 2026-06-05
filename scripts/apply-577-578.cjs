const { Client } = require('pg');
const fs = require('fs');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  for (const f of ['578_internal_system_fns.sql']) {
    const sql = fs.readFileSync(`database/migrations/${f}`, 'utf8');
    console.log(`--- Applying ${f} ---`);
    try { await c.query(sql); console.log(`OK: ${f}`); }
    catch (e) { console.error(`FAIL: ${f}: ${e.message}`); process.exit(1); }
  }
  const r = await c.query('SELECT version FROM schema_migrations WHERE version IN (577,578) ORDER BY version');
  console.log('Recorded:', r.rows.map(x => x.version).join(','));
  const seed = await c.query(`SELECT system_code, kind, vendor FROM internal_system_source WHERE is_active=TRUE ORDER BY id`);
  console.log(`Seeded ${seed.rows.length} rows:`);
  seed.rows.forEach((x) => console.log(`  ${x.system_code} (${x.kind}/${x.vendor})`));
  await c.end();
})();
