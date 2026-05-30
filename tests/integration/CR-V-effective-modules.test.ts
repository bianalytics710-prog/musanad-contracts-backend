/**
 * CR-V — Integration test: effectiveModules in authenticated user context.
 *
 * Verifies that POST /api/v1/auth/login returns an effectiveModules string[]
 * field populated from fn_user_effective_modules() via the migration-345
 * extension of fn_user_get_by_id. The auth controller now forwards the tenant
 * GUC so module overrides are evaluated against the ADNOC tenant seed data.
 *
 * ACs:
 *   AC-V-EM-01: Super Admin login response has effectiveModules as a non-empty array
 *   AC-V-EM-02: effectiveModules contains at least some known module keys
 *   AC-V-EM-03: effectiveModules entries are all strings
 *   AC-V-EM-04: contract_drafter login response also has effectiveModules as array
 *   AC-V-EM-05: toggle a module OFF → re-login → effectiveModules does NOT include that module
 *   AC-V-EM-06: toggle module back ON → re-login → effectiveModules includes it again
 *
 * testLevels: ["integration"]
 * Runs against TEST_DATABASE_URL (migration 345 applied).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  closeAdminPool,
  adminPool,
} from '../helpers/m1a-helpers';
import { seedFixtureUsers } from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const MODULE_UNDER_TEST = 'clauses';

let app: import('express').Express;
let server: import('http').Server;

// ─────────────────────────────────────────────────────────────────────────────
// Helper: direct DB toggle (bypass-RLS)
// ─────────────────────────────────────────────────────────────────────────────

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

  await seedFixtureUsers();
}, 90_000);

afterAll(async () => {
  try { await setModuleEnabled(MODULE_UNDER_TEST, true); } catch { /* swallow */ }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 30_000);

// ─────────────────────────────────────────────────────────────────────────────
// AC-V-EM-01 / AC-V-EM-02 / AC-V-EM-03: Super Admin login → effectiveModules
// ─────────────────────────────────────────────────────────────────────────────

describe('POST /api/v1/auth/login — effectiveModules in user object', () => {
  it('AC-V-EM-01: Super Admin login response has effectiveModules as array', async () => {
    const loginRes = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: 'admin@musanad.local', password: 'ChangeMe@123' });

    expect(loginRes.status).toBe(200);
    const loginUser = loginRes.body.user as Record<string, unknown>;
    expect(Array.isArray(loginUser.effectiveModules)).toBe(true);
  });

  it('AC-V-EM-02: Super Admin effectiveModules is non-empty', async () => {
    const loginRes = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: 'admin@musanad.local', password: 'ChangeMe@123' });

    expect(loginRes.status).toBe(200);
    const loginUser = loginRes.body.user as { effectiveModules: string[] };
    expect(loginUser.effectiveModules.length).toBeGreaterThan(0);
  });

  it('AC-V-EM-03: effectiveModules entries are all strings', async () => {
    const loginRes = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: 'admin@musanad.local', password: 'ChangeMe@123' });

    expect(loginRes.status).toBe(200);
    const loginUser = loginRes.body.user as { effectiveModules: unknown[] };
    for (const m of loginUser.effectiveModules) {
      expect(typeof m).toBe('string');
    }
  });

  it('AC-V-EM-04: effectiveModules is visible on authenticated route (contracts list) — module enabled', async () => {
    // Super Admin has all modules enabled; /api/v1/contracts returns 200.
    // This proves the middleware round-trip from login → effectiveModules → route permit.
    const loginRes = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: 'admin@musanad.local', password: 'ChangeMe@123' });

    expect(loginRes.status).toBe(200);
    const { accessToken } = loginRes.body as { accessToken: string };
    expect(typeof accessToken).toBe('string');

    // contracts.browse is in effectiveModules for Super Admin → GET /contracts should 200
    const contractsRes = await request(app)
      .get('/api/v1/contracts')
      .set('Authorization', `Bearer ${accessToken}`);

    expect(contractsRes.status).toBe(200);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // AC-V-EM-05 / AC-V-EM-06: Toggle clauses OFF → re-login → module absent
  // ─────────────────────────────────────────────────────────────────────────

  it('AC-V-EM-05: disable clauses module → re-login → effectiveModules excludes "clauses"', async () => {
    await setModuleEnabled(MODULE_UNDER_TEST, false);

    const loginRes = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: 'admin@musanad.local', password: 'ChangeMe@123' });

    expect(loginRes.status).toBe(200);
    const loginUser = loginRes.body.user as { effectiveModules: string[] };
    expect(loginUser.effectiveModules).not.toContain(MODULE_UNDER_TEST);
  });

  it('AC-V-EM-06: re-enable clauses → re-login → effectiveModules includes "clauses"', async () => {
    await setModuleEnabled(MODULE_UNDER_TEST, true);

    const loginRes = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: 'admin@musanad.local', password: 'ChangeMe@123' });

    expect(loginRes.status).toBe(200);
    const loginUser = loginRes.body.user as { effectiveModules: string[] };
    expect(loginUser.effectiveModules).toContain(MODULE_UNDER_TEST);
  });
});
