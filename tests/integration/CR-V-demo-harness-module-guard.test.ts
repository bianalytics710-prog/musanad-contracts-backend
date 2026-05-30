/**
 * CR-V — Integration test: Demo harness scenario trigger module guard.
 *
 * Verifies that POST /api/v1/admin/demo/scenarios/:id/trigger returns
 * { prepared: false, reason: 'module_disabled', moduleKey, scenarioCode }
 * when the underlying scenario's required module is disabled, rather than
 * forwarding to fn_demo_scenario_trigger.
 *
 * Scenarios with module guards (from SCENARIO_MODULE_MAP in demo-harness.service.ts):
 *   labor_cascade   → regulatory_cascade
 *   budget_burn     → financial.budget_burn
 *   trade_margin    → financial.trade_margin
 *
 * We use trade_margin in this test (same module used by CR-V-require-module-middleware.test.ts).
 * Test DB isolation: the module is restored in afterAll.
 *
 * ACs:
 *   AC-V-DH-01: trigger trade_margin scenario with module ON → responds (not module_disabled)
 *   AC-V-DH-02: toggle financial.trade_margin OFF → trigger → { prepared:false, reason:'module_disabled' }
 *   AC-V-DH-03: response body includes moduleKey and scenarioCode fields
 *   AC-V-DH-04: labor_cascade scenario (regulatory_cascade module): toggle off → same guard
 *
 * testLevels: ["integration"]
 * Runs against TEST_DATABASE_URL (migrations through 345 applied).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  loginAdmin,
  closeAdminPool,
  adminPool,
  adminQuery,
  type LoginResult,
} from '../helpers/m1a-helpers';
import { seedFixtureUsers, signFixtureToken } from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const TRADE_MARGIN_MODULE = 'financial.trade_margin';
const REG_CASCADE_MODULE = 'regulatory_cascade';
// scenario_id strings from demo_scenario table (seeded by migration 240)
const TRADE_MARGIN_SCENARIO_ID = 'trade_margin';
const LABOR_CASCADE_SCENARIO_ID = 'labor_cascade';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let platformAdminToken: string;

// Confirm scenarios exist in DB (if table not seeded, tests skip gracefully)
let tradeMarginScenarioExists = false;
let laborCascadeScenarioExists = false;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
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

  admin = await loginAdmin(app);
  await seedFixtureUsers();
  platformAdminToken = signFixtureToken('platform_admin1');

  // Verify scenarios exist in DB (demo_scenario.scenario_id = string identifier)
  const scenarios = await adminQuery<{ scenario_id: string }>(
    `SELECT scenario_id FROM demo_scenario WHERE is_active = TRUE`,
  );
  const scenarioIds = scenarios.map((s) => s.scenario_id);
  tradeMarginScenarioExists = scenarioIds.includes(TRADE_MARGIN_SCENARIO_ID);
  laborCascadeScenarioExists = scenarioIds.includes(LABOR_CASCADE_SCENARIO_ID);
}, 90_000);

afterAll(async () => {
  // Restore both modules regardless of test outcome
  try { await setModuleEnabled(TRADE_MARGIN_MODULE, true); } catch { /* swallow */ }
  try { await setModuleEnabled(REG_CASCADE_MODULE, true); } catch { /* swallow */ }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 30_000);

// ─────────────────────────────────────────────────────────────────────────────
// AC-V-DH-01: module ON → trigger resolves (no module_disabled)
// ─────────────────────────────────────────────────────────────────────────────

describe('Demo harness scenario trigger module guard', () => {
  it('AC-V-DH-01: trade_margin scenario with module ON → not module_disabled', async () => {
    if (!tradeMarginScenarioExists) {
      console.warn('trade_margin scenario not found in DB — skipping AC-V-DH-01');
      return;
    }
    await setModuleEnabled(TRADE_MARGIN_MODULE, true);

    const res = await request(app)
      .post(`/api/v1/admin/demo/scenarios/${TRADE_MARGIN_SCENARIO_ID}/trigger`)
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({});

    // Should succeed (scenario runs) — not a module_disabled response
    expect(res.status).not.toBe(404);
    const body = res.body as Record<string, unknown>;
    expect(body.reason).not.toBe('module_disabled');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // AC-V-DH-02 / AC-V-DH-03: module OFF → module_disabled
  // ─────────────────────────────────────────────────────────────────────────

  it('AC-V-DH-02: toggle financial.trade_margin OFF → trigger → prepared:false, reason:module_disabled', async () => {
    if (!tradeMarginScenarioExists) {
      console.warn('trade_margin scenario not found — skipping AC-V-DH-02');
      return;
    }
    await setModuleEnabled(TRADE_MARGIN_MODULE, false);

    const res = await request(app)
      .post(`/api/v1/admin/demo/scenarios/${TRADE_MARGIN_SCENARIO_ID}/trigger`)
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({});

    expect(res.status).toBe(200);
    const body = res.body as {
      prepared: boolean;
      reason: string;
      moduleKey: string;
      scenarioCode: string;
    };
    expect(body.prepared).toBe(false);
    expect(body.reason).toBe('module_disabled');
  });

  it('AC-V-DH-03: module_disabled response has moduleKey and scenarioCode', async () => {
    if (!tradeMarginScenarioExists) {
      console.warn('trade_margin scenario not found — skipping AC-V-DH-03');
      return;
    }
    // Module still OFF from previous test
    const res = await request(app)
      .post(`/api/v1/admin/demo/scenarios/${TRADE_MARGIN_SCENARIO_ID}/trigger`)
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({});

    const body = res.body as {
      prepared: boolean;
      reason: string;
      moduleKey: string;
      scenarioCode: string;
    };
    expect(body.moduleKey).toBe(TRADE_MARGIN_MODULE);
    expect(typeof body.scenarioCode).toBe('string');
    expect(body.scenarioCode.length).toBeGreaterThan(0);

    // Restore
    await setModuleEnabled(TRADE_MARGIN_MODULE, true);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // AC-V-DH-04: labor_cascade scenario → regulatory_cascade module guard
  // ─────────────────────────────────────────────────────────────────────────

  it('AC-V-DH-04: labor_cascade scenario with regulatory_cascade OFF → module_disabled', async () => {
    if (!laborCascadeScenarioExists) {
      console.warn('labor_cascade scenario not found — skipping AC-V-DH-04');
      return;
    }
    await setModuleEnabled(REG_CASCADE_MODULE, false);

    const res = await request(app)
      .post(`/api/v1/admin/demo/scenarios/${LABOR_CASCADE_SCENARIO_ID}/trigger`)
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({});

    expect(res.status).toBe(200);
    const body = res.body as { prepared: boolean; reason: string; moduleKey: string };
    expect(body.prepared).toBe(false);
    expect(body.reason).toBe('module_disabled');
    expect(body.moduleKey).toBe(REG_CASCADE_MODULE);

    // Restore
    await setModuleEnabled(REG_CASCADE_MODULE, true);
  });
});
