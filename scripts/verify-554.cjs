'use strict';
const { Pool } = require('pg');
const M0 = 'postgresql://neondb_owner:npg_Bqa05kgfzKUO@ep-still-violet-aj0h962i-pooler.c-3.us-east-2.aws.neon.tech/neondb?channel_binding=require&sslmode=require';

(async () => {
  const p = new Pool({ connectionString: M0 });
  const c = await p.connect();
  try {
    const v = await c.query('SELECT version, description, applied_at FROM schema_migrations WHERE version = 554');
    console.log('migration row:', v.rows);

    const t = await c.query(`SELECT to_regclass('contract_renewal_alert_event') AS t`);
    console.log('table:', t.rows);

    const f = await c.query(`SELECT proname FROM pg_proc WHERE proname IN ('fn_contract_renewal_alert_send','fn_dashboard_executive_expiring_contracts') ORDER BY 1`);
    console.log('fns:', f.rows);

    const perm = await c.query(`SELECT code FROM permission WHERE code = 'contract.renewal_alert.send'`);
    console.log('permission:', perm.rows);

    const grants = await c.query(`SELECT r.name FROM role_permission rp JOIN role r ON r.id=rp.role_id JOIN permission p ON p.id=rp.permission_id WHERE p.code='contract.renewal_alert.send' AND rp.is_active=TRUE ORDER BY r.name`);
    console.log('grants:', grants.rows);

    // Smoke: set tenant + user context = Eman Al Mazrouei and call expiring fn
    const u = await c.query(`SELECT u.id, u.tenant_id, r.name as role FROM "user" u JOIN role r ON r.id=u.role_id WHERE lower(u.email)='executive@musanad.local' LIMIT 1`);
    console.log('exec user:', u.rows);
    if (u.rows.length) {
      await c.query(`SET LOCAL app.current_tenant_id = '${u.rows[0].tenant_id}'`);
      await c.query(`SET LOCAL app.current_user_id  = '${u.rows[0].id}'`);
      const r = await c.query(`SELECT jsonb_path_query_array(fn_dashboard_executive_expiring_contracts(30), '$.rows[*]') AS rows`);
      const rows = r.rows[0]?.rows || [];
      console.log('30d rows count:', rows.length);
      // Look for OQOOD-2026-008 specifically
      const oqood008 = rows.find(x => x.contractNumber === 'OQOOD-2026-008');
      console.log('OQOOD-2026-008 row:', oqood008);
    }
  } finally {
    c.release();
    await p.end();
  }
})().catch(e => { console.error(e.message); process.exit(1); });
