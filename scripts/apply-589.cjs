const { Client } = require('pg');
const fs = require('fs');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const f = '589_dispatch_audit_fixes.sql';
  const sql = fs.readFileSync(`database/migrations/${f}`, 'utf8');
  console.log(`--- Applying ${f} ---`);
  try { await c.query(sql); console.log(`OK: ${f}`); }
  catch (e) { console.error(`FAIL: ${f}: ${e.message}`); process.exit(1); }
  const r = await c.query('SELECT version, description FROM schema_migrations WHERE version = 589');
  console.log('Recorded:', r.rows);
  await c.end();
})();
