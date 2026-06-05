const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const r = await c.query(
    `SELECT id, name_en, is_active,
            CASE WHEN body_embedding IS NULL THEN 'NULL' ELSE 'set' END AS embed,
            length(COALESCE(body_en,'')) AS body_len,
            created_at, updated_at
       FROM contract_template WHERE id = 23`,
  );
  console.log(JSON.stringify(r.rows[0], null, 2));
  await c.end();
})();
