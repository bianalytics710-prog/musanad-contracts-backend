const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const r = await c.query(
    `SELECT column_name, data_type, is_nullable, column_default
       FROM information_schema.columns
      WHERE table_schema='public' AND table_name='role_permission'
      ORDER BY ordinal_position`,
  );
  r.rows.forEach((x) => console.log(`  ${x.column_name.padEnd(20)} ${x.data_type.padEnd(20)} ${x.is_nullable} dflt=${x.column_default || ''}`));
  await c.end();
})();
