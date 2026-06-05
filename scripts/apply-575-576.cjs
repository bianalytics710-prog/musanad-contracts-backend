const { Client } = require('pg');
const fs = require('fs');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  for (const f of ['575_template_clause_embeddings.sql', '576_template_match_fns.sql']) {
    const sql = fs.readFileSync(`database/migrations/${f}`, 'utf8');
    console.log(`--- Applying ${f} ---`);
    try { await c.query(sql); console.log(`OK: ${f}`); }
    catch (e) { console.error(`FAIL: ${f}: ${e.message}`); process.exit(1); }
  }
  const r = await c.query('SELECT version FROM schema_migrations WHERE version IN (575,576) ORDER BY version');
  console.log('Recorded:', r.rows.map(x => x.version).join(','));
  await c.end();
})();
