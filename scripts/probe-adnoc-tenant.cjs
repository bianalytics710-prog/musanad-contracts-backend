const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const r = await c.query("SELECT id, slug, name FROM tenant WHERE is_active = TRUE ORDER BY id");
  r.rows.forEach((x) => console.log(`${x.id} | ${x.slug} | ${x.name}`));
  await c.end();
})();
