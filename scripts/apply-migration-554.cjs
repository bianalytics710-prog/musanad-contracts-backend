#!/usr/bin/env node
/**
 * Applies migration 554 to both branches (M0 + TEST).
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');

const M0_URL = 'postgresql://neondb_owner:npg_Bqa05kgfzKUO@ep-still-violet-aj0h962i-pooler.c-3.us-east-2.aws.neon.tech/neondb?channel_binding=require&sslmode=require';
const TEST_URL = 'postgresql://neondb_owner:npg_Bqa05kgfzKUO@ep-nameless-pond-ajnaaomh-pooler.c-3.us-east-2.aws.neon.tech/neondb?channel_binding=require&sslmode=require';

const FILE = path.resolve(__dirname, '..', 'database', 'migrations', '554_contract_renewal_alert_infra.sql');
const SQL = fs.readFileSync(FILE, 'utf-8');

async function apply(label, url) {
  const pool = new Pool({ connectionString: url });
  const client = await pool.connect();
  try {
    const already = await client.query('SELECT 1 FROM schema_migrations WHERE version = 554');
    if (already.rowCount > 0) {
      console.log(`[${label}] 554 SKIP (already applied)`);
      return;
    }
    const t0 = Date.now();
    await client.query(SQL);  // migration itself wraps BEGIN/COMMIT
    console.log(`[${label}] 554 OK ${Date.now() - t0}ms`);
  } catch (e) {
    console.error(`[${label}] 554 FAIL: ${e.message}`);
    throw e;
  } finally {
    client.release();
    await pool.end();
  }
}

(async () => {
  await apply('M0', M0_URL);
  await apply('TEST', TEST_URL);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
