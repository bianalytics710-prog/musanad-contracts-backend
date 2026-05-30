/**
 * CR-V — Integration test: requireModuleEnabled middleware behaviour.
 *
 * Toggles a module off via direct DB write (bypass-RLS), then verifies the
 * gated HTTP route returns 404+MODULE_DISABLED. Toggles back on and confirms
 * the route is accessible again.
 *
 * We use financial.trade_margin for this test because:
 *   - It has a clear gated route (/api/v1/financial/trade-margin)
 *   - It has a seeded product_module_enable row for ADNOC tenant (migration 341)
 *   - finance_treasury role is in its default_role_codes
 *
 * ACs:
 *   AC-V-MW-01: finance_treasury → /financial/trade-margin → 200 (module on)
 *   AC-V-MW-02: toggle financial.trade_margin OFF → same route → 404 + MODULE_DISABLED code
 *   AC-V-MW-03: response body has { success:false, error.code:'MODULE_DISABLED', moduleKey }
 *   AC-V-MW-04: toggle financial.trade_margin ON → route returns 200 again
 *   AC-V-MW-05: unauthenticated request → 401 (auth check fires before module check)
 *
 * testLevels: ["integration"]
 * Runs against TEST_DATABASE_URL (migrations 336..345 applied).
 * ADNOC tenant id = '00000000-0000-0000-0000-000000000001'.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  closeAdminPool,
  adminPool,
} from '../helpers/m1a-helpers';
import {
  seedFixtureUsers,
} from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const MODULE_UNDER_TEST = 'financial.trade_margin';
const GATED_ROUTE = '/api/v1/financial/trade-margin';

let app: import('express').Express;
let server: import('http').Server;

// finance_treasury fixture user token
let financeTreasuryToken: string;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers: direct DB toggle (bypass-RLS — test branch isolation)
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

async function seedFinanceTreasuryUser(): Promise<number> {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const roleRes = await client.query<{ id: number }>(
      `SELECT id FROM role WHERE name = 'finance_treasury' AND is_active = TRUE LIMIT 1`,
    );
    const roleId = roleRes.rows[0]?.id;
    if (!roleId) throw new Error("Role 'finance_treasury' not found");
    const userRes = await client.query<{ id: number }>(
      `INSERT INTO "user" (email, password_hash, first_name, last_name, role_id, is_active, created_by, updated_by)
         VALUES ('crv-mw-ft@test.crv',
                 '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS',
                 'CRV', 'FT', $1, TRUE, 1, 1)
       ON CONFLICT (email) DO UPDATE SET role_id = EXCLUDED.role_id, is_active = TRUE, updated_by = 1
       RETURNING id`,
      [roleId],
    );
    await client.query('COMMIT');
    return Number(userRes.rows[0]!.id);
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

  const ftUserId = await seedFinanceTreasuryUser();
  const { signAccessToken } = await import('../../src/utils/jwt.util');
  financeTreasuryToken = signAccessToken({ userId: ftUserId, role: 'finance_treasury' });
}, 90_000);

afterAll(async () => {
  // Always restore module to enabled regardless of test outcome
  try {
    await setModuleEnabled(MODULE_UNDER_TEST, true);
  } catch { /* swallow — cleanup best-effort */ }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 30_000);

// ─────────────────────────────────────────────────────────────────────────────
// AC-V-MW-01: Module on → 200
// ─────────────────────────────────────────────────────────────────────────────

describe(`requireModuleEnabled('${MODULE_UNDER_TEST}') — toggle off → 404, back on → 200`, () => {
  it('AC-V-MW-01: module ON → GET /financial/trade-margin → 200', async () => {
    await setModuleEnabled(MODULE_UNDER_TEST, true);

    const res = await request(app)
      .get(GATED_ROUTE)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(200);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // AC-V-MW-02 / AC-V-MW-03: Module off → 404 + MODULE_DISABLED
  // ─────────────────────────────────────────────────────────────────────────

  it('AC-V-MW-02: module OFF → GET /financial/trade-margin → 404', async () => {
    await setModuleEnabled(MODULE_UNDER_TEST, false);

    const res = await request(app)
      .get(GATED_ROUTE)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(404);
  });

  it('AC-V-MW-03: 404 body has success:false, error.code MODULE_DISABLED, moduleKey field', async () => {
    // Module is still OFF from prior test (tests run sequentially within describe)
    const res = await request(app)
      .get(GATED_ROUTE)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(404);
    const body = res.body as {
      success: boolean;
      error: { code: string; message: string };
      moduleKey: string;
    };
    expect(body.success).toBe(false);
    expect(body.error.code).toBe('MODULE_DISABLED');
    expect(typeof body.error.message).toBe('string');
    expect(body.moduleKey).toBe(MODULE_UNDER_TEST);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // AC-V-MW-04: Toggle back ON → 200
  // ─────────────────────────────────────────────────────────────────────────

  it('AC-V-MW-04: toggle module ON again → GET /financial/trade-margin → 200', async () => {
    await setModuleEnabled(MODULE_UNDER_TEST, true);

    const res = await request(app)
      .get(GATED_ROUTE)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(200);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // AC-V-MW-05: Unauthenticated → 401 (auth check before module check)
  // ─────────────────────────────────────────────────────────────────────────

  it('AC-V-MW-05: unauthenticated request → 401 (not 404)', async () => {
    const res = await request(app).get(GATED_ROUTE);
    expect(res.status).toBe(401);
  });
});
