/**
 * Find anything added since the cleanup point so we know what to soft-delete.
 * Cleanup ran at ~14:42 UTC today; anything created after that and still
 * active is from the user's manual test.
 */
const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();

  const t = await c.query(
    `SELECT id, name_en, contract_type, created_at
       FROM contract_template
      WHERE is_active = TRUE AND created_at > '2026-06-05 14:42:00+00'
      ORDER BY id`,
  );
  console.log(`Templates added since cleanup: ${t.rows.length}`);
  t.rows.forEach((r) => console.log(`  #${r.id} ${r.name_en} (${r.contract_type}) — ${r.created_at}`));

  const cl = await c.query(
    `SELECT id, title_en, category, created_at
       FROM contract_clause
      WHERE is_active = TRUE AND created_at > '2026-06-05 14:42:00+00'
      ORDER BY id`,
  );
  console.log(`\nClauses added since cleanup: ${cl.rows.length}`);
  cl.rows.forEach((r) => console.log(`  #${r.id} ${r.title_en} (${r.category}) — ${r.created_at}`));

  await c.end();
})();
