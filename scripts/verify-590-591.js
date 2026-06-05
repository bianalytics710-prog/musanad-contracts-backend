/* eslint-disable no-console */
/**
 * Verify mig 590 (ai_model_pricing + cost auto-fill) + mig 591 (settlement
 * trigger replacement).
 *
 * Probes:
 *   1. fn_ai_compute_cost_micros for the 3 seeded models.
 *   2. fn_ai_request_log_create — caller passes NULL cost, DB auto-fills.
 *   3. Settlement UPDATE (post-stream column updates) is now allowed; an
 *      attempt to mutate an identifying column is still rejected.
 *   4. Backfill — pre-590 historical rows have cost stamped.
 *
 * Marker payload field 'auditMarker' = 'audit-590-verify' so test rows are
 * easy to clean up.
 */
'use strict';
require('dotenv').config({ path: '.env.local' });
const { Pool } = require('pg');
const { randomUUID } = require('node:crypto');

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const MARKER = 'audit-590-verify';

(async () => {
  const c = await pool.connect();
  try {
    console.log('\n── 1. fn_ai_compute_cost_micros for seeded models ──');
    const cases = [
      ['gpt-4o',                 1_000_000, 1_000_000], // $5 + $15 = $20.00
      ['gpt-4o-mini',            1_000_000, 1_000_000], // $0.15 + $0.60 = $0.75
      ['text-embedding-3-small', 1_000_000, 0],         // $0.02
      ['unknown-model',          1000,      500],       // expect null
    ];
    const tbl = [];
    for (const [m, ti, to] of cases) {
      const r = await c.query(
        'SELECT fn_ai_compute_cost_micros($1, $2, $3, NOW()) AS micros',
        [m, ti, to]
      );
      const micros = r.rows[0].micros;
      tbl.push({ model: m, tokens_in: ti, tokens_out: to, cost_micros: micros, cost_usd: micros ? (micros / 1e6).toFixed(4) : null });
    }
    console.table(tbl);

    console.log('\n── 2. fn_ai_request_log_create with NULL cost auto-fills ──');
    const promptRow = (await c.query(
      `SELECT prompt_id FROM ai_prompt WHERE is_active = TRUE LIMIT 1`
    )).rows[0];
    const promptId = promptRow.prompt_id;
    const requestId = randomUUID();
    const insert = await c.query(
      `SELECT fn_ai_request_log_create(
         $1::uuid, $2::text, 'verify', NULL::bigint,
         'audit_verify', NULL::bigint, 'en', 'openai', 'gpt-4o',
         1500, 800,
         NULL::bigint,             -- cost passed as NULL
         123, FALSE, FALSE,
         'success', NULL::text, NULL::text
       ) AS result`,
      [requestId, promptId]
    );
    console.log(JSON.stringify(insert.rows[0].result, null, 2));

    const row = await c.query(
      `SELECT id, model_used, tokens_input, tokens_output, cost_usd_micros, outcome
         FROM ai_request_log WHERE request_id = $1`,
      [requestId]
    );
    console.log('Row written:');
    console.table(row.rows);

    console.log('\n── 3a. Settlement UPDATE — outcome + tokens (allowed) ──');
    const upd1 = await c.query(
      `UPDATE ai_request_log
          SET tokens_output = 1200,
              cost_usd_micros = fn_ai_compute_cost_micros(model_used, tokens_input, 1200, created_at),
              outcome = 'success',
              latency_ms = 999
        WHERE request_id = $1
        RETURNING id, tokens_output, cost_usd_micros, latency_ms`,
      [requestId]
    );
    console.table(upd1.rows);

    console.log('\n── 3b. Identifying-column UPDATE — should be rejected ──');
    try {
      await c.query(
        `UPDATE ai_request_log SET model_used = 'tampered' WHERE request_id = $1`,
        [requestId]
      );
      console.log('!! REGRESSION — identifying column UPDATE did NOT raise.');
    } catch (e) {
      console.log(`  OK — rejected with ${e.code}: ${e.message.split('\n')[0]}`);
    }

    console.log('\n── 4. Historical backfill stats ──');
    const stats = await c.query(`
      SELECT
        COUNT(*) FILTER (WHERE cost_usd_micros IS NOT NULL)::int AS rows_with_cost,
        COUNT(*) FILTER (WHERE cost_usd_micros IS NULL AND model_used <> 'unknown' AND model_used IS NOT NULL AND (tokens_input IS NOT NULL OR tokens_output IS NOT NULL))::int AS rows_should_have_cost_but_null,
        ROUND(SUM(cost_usd_micros)::numeric / 1e6, 4) AS total_usd
      FROM ai_request_log
    `);
    console.table(stats.rows);

    console.log('\n── 5. Cleanup ──');
    const del = await c.query(
      `UPDATE ai_request_log SET is_active = FALSE WHERE request_id = $1 RETURNING id`,
      [requestId]
    );
    console.log(`Soft-deactivated ${del.rowCount} test row(s).`);

    console.log('\nDone.');
  } finally {
    c.release();
    await pool.end();
  }
})().catch((e) => { console.error('VERIFY FAILED', e); process.exitCode = 1; });
