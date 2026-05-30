/**
 * CR-V — Integration test: Worker module-enabled guard.
 *
 * Workers call fn_module_enabled(tenantId, moduleKey) at the top of their
 * per-item processing function and return early when the module is disabled.
 *
 * This test validates the guard behaviour at the DB level: fn_module_enabled
 * returns false when product_module_enable.is_enabled=FALSE, and returns
 * true when enabled. The actual workers run in-process under NODE_ENV=test
 * guard (no-op) so we verify the guard predicate directly + confirm that
 * the HTTP routes (which share the same module predicate) reflect the state.
 *
 * Additionally, we verify that disabling the 'clauses' module causes the
 * clause-extraction worker's route (/api/v1/clauses) to return 404.
 *
 * ACs:
 *   AC-V-WG-01: fn_module_enabled(ADNOC_TENANT, 'risk_cases') returns TRUE (default)
 *   AC-V-WG-02: toggle risk_cases OFF → fn_module_enabled returns FALSE
 *   AC-V-WG-03: toggle risk_cases ON → fn_module_enabled returns TRUE again
 *   AC-V-WG-04: toggle 'clauses' OFF → GET /api/v1/clauses returns 404 (route guard)
 *   AC-V-WG-05: toggle 'clauses' ON  → GET /api/v1/clauses returns 200 again
 *   AC-V-WG-06: fn_module_enabled for unknown key returns FALSE (not error)
 *
 * testLevels: ["integration"]
 * Runs against TEST_DATABASE_URL (migrations 336..345 applied).
 * ADNOC tenant id = '00000000-0000-0000-0000-000000000001'.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  loginAdmin,
  closeAdminPool,
  adminPool,
  type LoginResult,
} from '../helpers/m1a-helpers';
import { seedFixtureUsers, signFixtureToken } from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let platformAdminToken: string;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

async function callFnModuleEnabled(tenantId: string, moduleKey: string): Promise<boolean> {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      `SELECT set_config('app.current_user_id', '1', true)`,
    );
    await client.query(
      `SELECT set_config('app.current_tenant_id', $1, true)`,
      [tenantId],
    );
    const res = await client.query<{ fn_module_enabled: boolean }>(
      'SELECT fn_module_enabled($1::uuid, $2::text) AS fn_module_enabled',
      [tenantId, moduleKey],
    );
    await client.query('COMMIT');
    return res.rows[0]?.fn_module_enabled ?? false;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    throw err;
  } finally {
    client.release();
  }
}

async function setModuleEnabled(moduleKey: string, isEnabled: boolean): Promise<void> {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      `UPDATE product_module_enable
          SET is_enabled = $1, updated_at = NOW()
        WHERE module_key = $2
          AND tenant_id  = $3
          AND is_active  = TRUE`,
      [isEnabled, moduleKey, ADNOC_TENANT_ID],
    );
    await client.query('COMMIT');
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    throw err;
  } finally {
    client.release();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Setup / teardown
// ─────────────────────────────────────────────────────────────────────────────

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;

  admin = await loginAdmin(app);
  await seedFixtureUsers();
  platformAdminToken = signFixtureToken('platform_admin1');
}, 90_000);

afterAll(async () => {
  // Restore all modules touched in this file
  try { await setModuleEnabled('risk_cases', true); } catch { /* swallow */ }
  try { await setModuleEnabled('clauses', true); } catch { /* swallow */ }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 30_000);

// ─────────────────────────────────────────────────────────────────────────────
// fn_module_enabled predicate
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_module_enabled — worker guard predicate', () => {
  it('AC-V-WG-01: risk_cases enabled by default → fn_module_enabled returns TRUE', async () => {
    await setModuleEnabled('risk_cases', true);
    const result = await callFnModuleEnabled(ADNOC_TENANT_ID, 'risk_cases');
    expect(result).toBe(true);
  });

  it('AC-V-WG-02: toggle risk_cases OFF → fn_module_enabled returns FALSE', async () => {
    await setModuleEnabled('risk_cases', false);
    const result = await callFnModuleEnabled(ADNOC_TENANT_ID, 'risk_cases');
    expect(result).toBe(false);
  });

  it('AC-V-WG-03: toggle risk_cases ON → fn_module_enabled returns TRUE again', async () => {
    await setModuleEnabled('risk_cases', true);
    const result = await callFnModuleEnabled(ADNOC_TENANT_ID, 'risk_cases');
    expect(result).toBe(true);
  });

  it('AC-V-WG-06: unknown module key → fn_module_enabled returns FALSE (no error)', async () => {
    const result = await callFnModuleEnabled(ADNOC_TENANT_ID, 'non_existent_module_xyz');
    expect(result).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Route-level guard (proxy for worker guard: same fn_module_enabled predicate)
// ─────────────────────────────────────────────────────────────────────────────

describe('clauses module toggle → route guard reflects module state', () => {
  it('AC-V-WG-04: clauses OFF → GET /api/v1/clauses → 404 MODULE_DISABLED', async () => {
    await setModuleEnabled('clauses', false);

    const res = await request(app)
      .get('/api/v1/clauses')
      .set('Authorization', `Bearer ${admin.accessToken}`);

    expect(res.status).toBe(404);
    const body = res.body as { error?: { code?: string } };
    expect(body.error?.code).toBe('MODULE_DISABLED');
  });

  it('AC-V-WG-05: clauses ON → GET /api/v1/clauses → 200 again', async () => {
    await setModuleEnabled('clauses', true);

    const res = await request(app)
      .get('/api/v1/clauses')
      .set('Authorization', `Bearer ${admin.accessToken}`);

    expect(res.status).toBe(200);
  });
});
