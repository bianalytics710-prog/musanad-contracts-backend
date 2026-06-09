const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  await c.query('BEGIN');
  await c.query("SELECT set_config('app.current_tenant_id','00000000-0000-0000-0000-000000000001',true)");
  await c.query("SELECT set_config('app.current_user_id','4',true)");
  const payload = { subject: 'Smoke', bodyRendered: 'Smoke body', contractId: 7, contractNumber: 'OQOOD-2026-003' };
  const r = await c.query(
    `SELECT fn_notification_dispatch($1::bigint, $2::text, $3::jsonb, $4::text, $5::text, $6::bigint, NULL::text)::jsonb AS res`,
    [4, 'approval.requested_changes', JSON.stringify(payload), 'inbox', 'high', 5],
  );
  console.log('dispatch result:', JSON.stringify(r.rows[0].res, null, 2));

  const ndl = await c.query(
    "SELECT id, recipient_user_id, channel, subject, status, error_message FROM notification_dispatch_log WHERE created_at >= NOW() - INTERVAL '30 seconds' ORDER BY id DESC",
  );
  console.log('\nnotification_dispatch_log:');
  for (const x of ndl.rows) console.log(' ', x);

  await c.query('ROLLBACK');
  await c.end();
})();
