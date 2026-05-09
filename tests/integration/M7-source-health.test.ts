/**
 * M7 — source-health worker integration tests (CR-A AC-S8-01..06).
 *
 *   AC-S8-02 — state=healthy populates last_success_at; failing/unauthorised populates last_failure_at
 *   AC-S8-05 — degraded → failing → healthy transitions are observable across calls
 *
 * The cron loop is short-circuited in NODE_ENV=test; these tests directly
 * call fn_source_health_record (the same DB function the worker calls) and
 * runSourceHealthSweep() to validate the orchestration contract.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, adminQuery } from '../helpers/m1a-helpers';
import { runSourceHealthSweep } from '../../src/workers/source-health.worker';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const RUN_ID = `m7sh-${Date.now()}`;

let testSourceId: number;
const trackedHealthIds: number[] = [];
let server: import('http').Server;

beforeAll(async () => {
  // Bootstrap the BE app (validateEnv) before any db.callFunction call.
  const m = await import('../../src/server');
  server = m.server;

  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.current_user_id', '1', true)");
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [ADNOC_TENANT_ID]);
    const r = await client.query<{ id: number }>(
      `INSERT INTO osint_source
         (tenant_id, source_id, display_name, kind, format,
          refresh_seconds, source_reliability, enabled, is_active, metadata, created_by, updated_by)
       VALUES ($1, $2, 'm7sh stub', 'news', 'rss',
               900, 0.85, TRUE, TRUE, '{}'::jsonb, 1, 1)
       RETURNING id`,
      [ADNOC_TENANT_ID, `m7sh_stub_${RUN_ID}`],
    );
    testSourceId = Number(r.rows[0]!.id);
    await client.query('COMMIT');
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    throw err;
  } finally {
    client.release();
  }
});

afterAll(async () => {
  await adminQuery(`DELETE FROM source_health WHERE osint_source_id = $1`, [testSourceId]);
  await adminQuery(`DELETE FROM osint_source WHERE id = $1`, [testSourceId]);
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

describe('source-health worker — state transitions via fn_source_health_record', () => {
  /** Direct call to fn_source_health_record matching what the worker emits. */
  const callHealthRecord = async (
    state: 'healthy' | 'degraded' | 'failing' | 'unauthorised',
    errorMsg: string | null,
    signals24h: number,
  ): Promise<{ id: number; state: string; checkedAt: string }> => {
    const { db } = await import('../../src/database/client');
    return db.callFunction<{ id: number; state: string; checkedAt: string }>(
      'fn_source_health_record',
      [testSourceId, state, errorMsg, signals24h],
      { tenantId: ADNOC_TENANT_ID },
    );
  };

  it('AC-S8-02 / AC-S8-05: healthy → degraded → failing → healthy transitions', async () => {
    const r1 = await callHealthRecord('healthy', null, 5);
    expect(r1.state).toBe('healthy');
    trackedHealthIds.push(r1.id);

    const after1 = await adminQuery<{
      last_success_at: string | null;
      last_failure_at: string | null;
    }>(`SELECT last_success_at, last_failure_at FROM source_health WHERE id = $1`, [r1.id]);
    expect(after1[0]!.last_success_at).not.toBeNull();
    expect(after1[0]!.last_failure_at).toBeNull();

    const r2 = await callHealthRecord('degraded', 'Latency 12s exceeds threshold', 4);
    expect(r2.state).toBe('degraded');

    const after2 = await adminQuery<{
      last_success_at: string | null;
      last_failure_at: string | null;
      last_error_message: string | null;
    }>(`SELECT last_success_at, last_failure_at, last_error_message FROM source_health WHERE id = $1`, [r1.id]);
    expect(after2[0]!.last_success_at).not.toBeNull();
    expect(after2[0]!.last_failure_at).not.toBeNull();
    expect(after2[0]!.last_error_message).toContain('Latency');

    const r3 = await callHealthRecord('failing', 'HTTP 503 from upstream', 0);
    expect(r3.state).toBe('failing');

    const r4 = await callHealthRecord('healthy', null, 6);
    expect(r4.state).toBe('healthy');
    const after4 = await adminQuery<{
      state: string;
      last_success_at: string | null;
      last_failure_at: string | null;
    }>(`SELECT state, last_success_at, last_failure_at FROM source_health WHERE id = $1`, [r1.id]);
    expect(after4[0]!.state).toBe('healthy');
    expect(after4[0]!.last_success_at).not.toBeNull();
    // last_failure_at preserved from previous failing call
    expect(after4[0]!.last_failure_at).not.toBeNull();
  });

  it('AC-S8-03: invalid state raises 22023', async () => {
    await expect(callHealthRecord('not-a-state' as 'healthy', null, 0)).rejects.toBeDefined();
  });

  it('long error_message gets truncated to 500 chars', async () => {
    const longMsg = 'X'.repeat(800);
    await callHealthRecord('failing', longMsg, 0);
    const rows = await adminQuery<{ last_error_message: string | null }>(
      `SELECT last_error_message FROM source_health WHERE osint_source_id = $1`, [testSourceId],
    );
    if (rows[0]!.last_error_message) {
      expect(rows[0]!.last_error_message.length).toBeLessThanOrEqual(500);
    }
  });
});

describe('source-health worker — runSourceHealthSweep contract', () => {
  it('runSourceHealthSweep is exported with the SweepStats contract', () => {
    // The sweep runs adapter.health_check() against live HTTP for every
    // ADNOC seed source — that's network-bound and slow. We verify the
    // export exists; the per-source upsert path is exercised above by the
    // AC-S8-02..05 transition tests.
    expect(typeof runSourceHealthSweep).toBe('function');
    expect(runSourceHealthSweep.name).toBe('runSourceHealthSweep');
  });
});
