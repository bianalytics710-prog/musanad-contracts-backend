const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  await c.query('BEGIN');
  await c.query("SELECT set_config('app.current_tenant_id','00000000-0000-0000-0000-000000000001',true)");
  await c.query("SELECT set_config('app.current_user_id','4',true)");
  // template id 8 = approval.requested_changes.in_app
  try {
    const r = await c.query(
      `SELECT fn_notification_send($1::bigint, $2::bigint, $3::text, $4::text, $5::text, $6::bigint, NULL::text, $7::jsonb, NULL::bigint)::jsonb AS res`,
      [4, 8, 'inbox', 'in_app', 'high', 5, JSON.stringify({ subject: 'Smoke', bodyRendered: 'Smoke body', contractId: 7, contractNumber: 'OQOOD-2026-003' })],
    );
    console.log('send result:', r.rows[0].res);
  } catch (e) {
    console.error('SEND FAILED:', e.message, '| code:', e.code, '| where:', e.where);
  }
  await c.query('ROLLBACK');
  await c.end();
})();
