const { Client } = require('pg');
const fs = require('fs');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const f = '607_drafter_contracts_scope_and_recent_drafts_type.sql';
  const sql = fs.readFileSync(`database/migrations/${f}`, 'utf8');
  console.log(`--- Applying ${f} ---`);
  try { await c.query(sql); console.log(`OK: ${f}`); }
  catch (e) { console.error(`FAIL: ${f}: ${e.message}`); process.exit(1); }
  const r = await c.query('SELECT version, description FROM schema_migrations WHERE version = 607');
  console.log('Recorded:', r.rows);
  // Post-apply: Hala's drafter scope check
  // Look up Hala's actual user_id
  const halaQ = await c.query("SELECT id FROM \"user\" WHERE lower(first_name) = 'hala' AND is_active = TRUE LIMIT 1");
  const halaId = halaQ.rows[0]?.id;
  console.log("\nHala user_id:", halaId);
  await c.query("BEGIN");
  await c.query("SELECT set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', true)");
  await c.query(`SELECT set_config('app.current_user_id', '${halaId}', true)`);
  const halaContractList = await c.query(
    `SELECT (fn_contract_list(1, 20, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ${halaId}, 'contract_drafter', NULL, NULL, NULL, NULL, NULL, NULL, NULL)::jsonb)->'pagination' AS p`
  );
  console.log("Hala (drafter) — fn_contract_list pagination:", halaContractList.rows[0]?.p);
  const halaDash = await c.query("SELECT fn_dashboard_drafter()::jsonb->'kpis' AS k");
  console.log("Hala drafter dashboard KPIs:", halaDash.rows[0]?.k);
  const myDrafts = await c.query("SELECT fn_dashboard_drafter()::jsonb->'lists'->'myDrafts5'->0 AS row0");
  console.log("Sample myDrafts5[0] (should include contractType):", myDrafts.rows[0]?.row0);
  await c.query("ROLLBACK");
  await c.end();
})();
