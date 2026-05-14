#!/usr/bin/env node
/**
 * Applies CR-I + CR-J migrations 225..239 (+ any present 240+) to both branches.
 * Reads each .sql file and executes verbatim via pg client.
 * Reports per-file outcome + final schema_migrations head per branch.
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');

const M0_URL = 'postgresql://neondb_owner:npg_Bqa05kgfzKUO@ep-still-violet-aj0h962i-pooler.c-3.us-east-2.aws.neon.tech/neondb?channel_binding=require&sslmode=require';
const TEST_URL = 'postgresql://neondb_owner:npg_Bqa05kgfzKUO@ep-nameless-pond-ajnaaomh-pooler.c-3.us-east-2.aws.neon.tech/neondb?channel_binding=require&sslmode=require';

const MIG_DIR = path.resolve(__dirname, '..', 'database', 'migrations');

async function applyOne(pool, branchLabel, version, file) {
  const sql = fs.readFileSync(path.join(MIG_DIR, file), 'utf-8');
  const t0 = Date.now();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(sql);
    await client.query('COMMIT');
    const ms = Date.now() - t0;
    console.log(`  [${branchLabel}] ${version} ${file} OK ${ms}ms`);
    return { ok: true, ms };
  } catch (e) {
    try { await client.query('ROLLBACK'); } catch (_) {}
    console.log(`  [${branchLabel}] ${version} ${file} FAIL ${e.message}`);
    return { ok: false, error: e.message };
  } finally {
    client.release();
  }
}

async function applyAll(pool, branchLabel) {
  // Find files matching 22[5-9]_ or 24[0-9]_ that aren't yet applied
  const all = fs.readdirSync(MIG_DIR)
    .filter(f => /^(22[5-9]|2[34][0-9])_.+\.sql$/.test(f))
    .sort();
  // Check which are already applied
  const applied = (await pool.query('SELECT version FROM schema_migrations WHERE version BETWEEN 225 AND 299')).rows.map(r => r.version);
  const appliedSet = new Set(applied);

  const results = [];
  for (const f of all) {
    const v = Number(f.split('_')[0]);
    if (appliedSet.has(v)) {
      console.log(`  [${branchLabel}] ${v} ${f} SKIP (already applied)`);
      results.push({ file: f, version: v, status: 'skipped' });
      continue;
    }
    const r = await applyOne(pool, branchLabel, v, f);
    results.push({ file: f, version: v, ...r, status: r.ok ? 'applied' : 'failed' });
    if (!r.ok) {
      console.log(`  [${branchLabel}] stopping on failure`);
      return results;
    }
  }
  return results;
}

(async () => {
  for (const [label, url] of [['m0-foundation', M0_URL], ['test', TEST_URL]]) {
    console.log(`\n=== Branch: ${label} ===`);
    const pool = new Pool({ connectionString: url, max: 1 });
    try {
      const head0 = await pool.query('SELECT MAX(version) AS v FROM schema_migrations');
      console.log(`  starting head: ${head0.rows[0].v}`);
      const results = await applyAll(pool, label);
      const head1 = await pool.query('SELECT MAX(version) AS v FROM schema_migrations');
      console.log(`  ending head:   ${head1.rows[0].v}`);
      const failed = results.filter(r => r.status === 'failed');
      const applied = results.filter(r => r.status === 'applied');
      console.log(`  applied=${applied.length} failed=${failed.length} skipped=${results.length - applied.length - failed.length}`);
      if (failed.length) {
        console.log(`  FIRST FAILURE: ${failed[0].file} — ${failed[0].error}`);
        process.exitCode = 1;
        await pool.end();
        return;
      }
    } finally {
      await pool.end();
    }
  }
  console.log('\nALL DONE');
})().catch(e => { console.error(e); process.exit(2); });
