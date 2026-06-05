/**
 * Audit: list every notification/email-related table + any system_source-ish
 * table so we can tell what already exists vs. what we'd need to build.
 */
const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();

  // 1. Notification-related tables
  const n = await c.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema='public'
        AND (table_name ILIKE 'notification%' OR table_name ILIKE 'email%'
             OR table_name ILIKE 'advisory%' OR table_name ILIKE '%dispatch%'
             OR table_name ILIKE 'renewal_alert%')
      ORDER BY table_name`,
  );
  console.log('--- notification/email-ish tables ---');
  n.rows.forEach((r) => console.log('  ' + r.table_name));

  // 2. Source-ish tables (external sources + anything similar)
  const s = await c.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema='public'
        AND (table_name ILIKE '%source%' OR table_name ILIKE '%system%'
             OR table_name ILIKE 'osint%' OR table_name ILIKE 'integration%')
      ORDER BY table_name`,
  );
  console.log('\n--- source/system-ish tables ---');
  s.rows.forEach((r) => console.log('  ' + r.table_name));

  // 3. Anything called *_rule that might wire trigger→template
  const r = await c.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema='public' AND table_name ILIKE '%rule%'
      ORDER BY table_name`,
  );
  console.log('\n--- rule-ish tables ---');
  r.rows.forEach((x) => console.log('  ' + x.table_name));

  // 4. Inspect notification_template columns + sample
  console.log('\n--- notification_template cols ---');
  const cols = await c.query(
    `SELECT column_name, data_type
       FROM information_schema.columns
      WHERE table_schema='public' AND table_name='notification_template'
      ORDER BY ordinal_position`,
  );
  cols.rows.forEach((x) => console.log(`  ${x.column_name} : ${x.data_type}`));

  // 5. Count + list notification template IDs (to show what events have a template).
  const tids = await c.query(
    `SELECT template_id, channel FROM notification_template
     ORDER BY template_id LIMIT 40`,
  );
  console.log(`\nnotification_template rows: ${tids.rows.length}`);
  tids.rows.forEach((r) => console.log(`  ${r.template_id}  [${r.channel}]`));

  // 6. Check if there's a side-car table that maps (event/trigger → template).
  console.log('\n--- search for any column called event_type / trigger_type / template_id mapping ---');
  const m = await c.query(
    `SELECT table_name, column_name FROM information_schema.columns
      WHERE table_schema='public'
        AND column_name IN ('event_type','trigger_type','notification_template_id','template_id')
      ORDER BY table_name, column_name`,
  );
  m.rows.forEach((x) => console.log(`  ${x.table_name}.${x.column_name}`));

  await c.end();
})();
