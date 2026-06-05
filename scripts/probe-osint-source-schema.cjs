const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const cols = await c.query(
    `SELECT column_name, data_type, character_maximum_length, is_nullable, column_default
       FROM information_schema.columns
      WHERE table_schema='public' AND table_name='osint_source'
      ORDER BY ordinal_position`,
  );
  console.log('--- osint_source columns ---');
  cols.rows.forEach((x) => console.log(`  ${x.column_name.padEnd(28)} ${x.data_type.padEnd(28)} ${x.is_nullable === 'YES' ? 'NULL' : 'NOT NULL'}`));
  const ck = await c.query(
    `SELECT conname, pg_get_constraintdef(oid) AS def
       FROM pg_constraint
      WHERE conrelid = 'public.osint_source'::regclass AND contype = 'c'`,
  );
  console.log('\n--- check constraints ---');
  ck.rows.forEach((x) => console.log(`  ${x.conname}: ${x.def}`));
  const sc = await c.query(
    `SELECT column_name, data_type
       FROM information_schema.columns
      WHERE table_schema='public' AND table_name='source_credential'
      ORDER BY ordinal_position`,
  );
  console.log('\n--- source_credential columns ---');
  sc.rows.forEach((x) => console.log(`  ${x.column_name.padEnd(28)} ${x.data_type}`));
  await c.end();
})();
