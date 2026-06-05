const { Client } = require('pg');
const fs = require('fs');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const f = '590_ai_model_pricing.sql';
  const sql = fs.readFileSync(`database/migrations/${f}`, 'utf8');
  console.log(`--- Applying ${f} ---`);
  try { await c.query(sql); console.log(`OK: ${f}`); }
  catch (e) { console.error(`FAIL: ${f}: ${e.message}`); process.exit(1); }
  const r = await c.query('SELECT version, description FROM schema_migrations WHERE version = 590');
  console.log('Recorded:', r.rows);

  // Quick post-apply summary
  const pricing = await c.query('SELECT provider, model, input_price_per_1m_usd, output_price_per_1m_usd FROM ai_model_pricing ORDER BY model');
  console.log('\nai_model_pricing:');
  console.table(pricing.rows);

  const backfill = await c.query(`
    SELECT
      COUNT(*) FILTER (WHERE cost_usd_micros IS NOT NULL)::int AS rows_with_cost,
      COUNT(*) FILTER (WHERE cost_usd_micros IS NULL)::int     AS rows_null_cost,
      SUM(cost_usd_micros)::bigint                              AS total_micros
    FROM ai_request_log
    WHERE created_at > NOW() - INTERVAL '60 days'
  `);
  console.log('\nai_request_log post-backfill (last 60d):');
  console.table(backfill.rows);

  await c.end();
})();
