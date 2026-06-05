const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const r = await c.query(
    `SELECT id, name_en, contract_type, language,
            length(COALESCE(body_en, '')) AS body_len,
            SUBSTR(COALESCE(body_en,''), 1, 400) AS body_preview,
            description_en,
            CASE WHEN body_embedding IS NULL THEN 'NULL' ELSE 'set' END AS embed
       FROM contract_template
      WHERE id IN (9,10,11,22)
      ORDER BY id`,
  );
  console.log(JSON.stringify(r.rows, null, 2));
  await c.end();
})();
