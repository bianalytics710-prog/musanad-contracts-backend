const { Client } = require('pg');
const fs = require('fs');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  for (const f of ['579_notification_rule.sql', '580_notification_rule_fns.sql']) {
    const sql = fs.readFileSync(`database/migrations/${f}`, 'utf8');
    console.log(`--- Applying ${f} ---`);
    try { await c.query(sql); console.log(`OK: ${f}`); }
    catch (e) { console.error(`FAIL: ${f}: ${e.message}`); process.exit(1); }
  }
  const r = await c.query('SELECT version FROM schema_migrations WHERE version IN (579,580) ORDER BY version');
  console.log('Recorded:', r.rows.map(x => x.version).join(','));
  const t = await c.query('SELECT COUNT(*)::int AS n FROM notification_event_type');
  const u = await c.query('SELECT COUNT(*)::int AS n FROM notification_rule WHERE is_active=TRUE');
  console.log(`event_types: ${t.rows[0].n}, rules seeded: ${u.rows[0].n}`);
  await c.end();
})();
