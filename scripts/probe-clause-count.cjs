const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const r = await c.query(
    `SELECT COUNT(*)::int AS total,
            COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '5 minutes')::int AS recent
       FROM contract_clause WHERE is_active = TRUE`,
  );
  console.log(JSON.stringify(r.rows[0]));
  const r2 = await c.query(
    `SELECT id, title_en, created_at FROM contract_clause
      WHERE is_active = TRUE AND created_at > NOW() - INTERVAL '5 minutes'
      ORDER BY id DESC LIMIT 15`,
  );
  console.log('Recent additions:', r2.rows.length);
  r2.rows.forEach((r) => console.log(`  #${r.id} ${r.title_en}`));
  await c.end();
})();
