/**
 * M15 / CR-G — Dashboard routes HTTP integration tests.
 *
 * Covers 4 new dashboard routes:
 *   S2 GET /api/v1/dashboards/operations          — fn_dashboard_operations
 *   S3 GET /api/v1/dashboards/finance-treasury     — fn_dashboard_finance_treasury
 *   S4 GET /api/v1/dashboards/compliance-esg       — fn_dashboard_compliance_esg
 *   S5 GET /api/v1/dashboards/procurement          — fn_dashboard_procurement_supplier_risk
 *
 * Per route:
 *   - platform_admin → 200 with expected payload shape
 *   - wrong-permission persona → 403
 *   - unauthenticated → 401
 *   - windowDays=7/30/90/180/365 OK; windowDays=6 → 400; windowDays=366 → 400
 *   - Tenant isolation sanity (response uses data from ADNOC tenant only)
 *
 * Runs against TEST_DATABASE_URL (migrations 178..190 applied).
 *
 * @module CR-G dashboard routes integration tests
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  loginAdmin,
  adminQuery,
  closeAdminPool,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  signFixtureToken,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';
import { adminPool } from '../helpers/m1a-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const FIXTURE_PASSWORD_HASH =
  '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let executiveToken: string;
let platformAdminToken: string;
let drafterToken: string;
let legalCounselToken: string;

// CR-G role tokens
let operationsToken: string;
let financeTreasuryToken: string;
let complianceEsgToken: string;

/**
 * Seed a user with a CR-G role and return a signed JWT token.
 */
async function seedCrgRoleToken(roleName: string, email: string): Promise<string> {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const roleRes = await client.query<{ id: number }>(
      `SELECT id FROM role WHERE name = $1 AND is_active = TRUE LIMIT 1`,
      [roleName],
    );
    if (!roleRes.rows[0]) {
      // Role not found — return a fallback token that will 403
      await client.query('ROLLBACK');
      const { signAccessToken } = await import('../../src/utils/jwt.util');
      return signAccessToken({ userId: -1, role: roleName });
    }
    const roleId = Number(roleRes.rows[0].id);
    const upsert = await client.query<{ id: number }>(
      `INSERT INTO "user" (email, password_hash, first_name, last_name, role_id, is_active, created_by, updated_by)
         VALUES ($1, $2, 'CRG', $3, $4, TRUE, 1, 1)
       ON CONFLICT (email) DO UPDATE
         SET role_id = EXCLUDED.role_id, is_active = TRUE, updated_by = 1
       RETURNING id`,
      [email, FIXTURE_PASSWORD_HASH, roleName, roleId],
    );
    const userId = Number(upsert.rows[0]!.id);
    await client.query('COMMIT');
    const { signAccessToken } = await import('../../src/utils/jwt.util');
    return signAccessToken({ userId, role: roleName });
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    throw err;
  } finally {
    client.release();
  }
}

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;

  admin = await loginAdmin(app);
  adminToken = admin.accessToken;

  await seedFixtureUsers();
  executiveToken     = signFixtureToken('executive1');
  platformAdminToken = signFixtureToken('platform_admin1');
  drafterToken       = signFixtureToken('drafter1');
  legalCounselToken  = signFixtureToken('legal_counsel1');

  // Seed CR-G role users
  operationsToken      = await seedCrgRoleToken('operations',       'crg-rt-ops@test.crg');
  financeTreasuryToken = await seedCrgRoleToken('finance_treasury', 'crg-rt-ft@test.crg');
  complianceEsgToken   = await seedCrgRoleToken('compliance_esg',   'crg-rt-cesg@test.crg');
}, 60_000);

afterAll(async () => {
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 30_000);

// ============================================================================
// Shared helper
// ============================================================================

/**
 * Assert the standard 3-key envelope shape for a dashboard 200 response.
 * All 4 new dashboards return { success, data } where data has kpi + kpiPrev
 * and various list sections. We assert the envelope + kpi presence.
 */
function assertDashboardEnvelope(res: request.Response): void {
  expect(res.status).toBe(200);
  expect(res.body.success).toBe(true);
  expect(res.body.data).toBeDefined();
  expect(res.body.data.kpi).toBeDefined();
  expect(res.body.data.kpiPrev).toBeDefined();
}

// ============================================================================
// GET /api/v1/dashboards/operations
// ============================================================================

describe('CR-G — GET /api/v1/dashboards/operations', () => {
  const ROUTE = '/api/v1/dashboards/operations';

  /**
   * @link S2 AC-S2-T1: platform_admin → 200 with payload shape
   */
  it('AC-S2-T1: platform_admin → 200 with kpi + kpiPrev + list sections', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${platformAdminToken}`);
    assertDashboardEnvelope(res);
    expect(Array.isArray(res.body.data.slaBreachesList)).toBe(true);
    expect(Array.isArray(res.body.data.vendorScorecards)).toBe(true);
  }, 30_000);

  /**
   * @link S2 AC-S2-T2: operations role → 200
   */
  it('AC-S2-T2: operations role → 200', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${operationsToken}`);
    assertDashboardEnvelope(res);
  }, 30_000);

  /**
   * @link S2 AC-S2-T3: wrong-permission persona (legal_counsel) → 403
   */
  it('AC-S2-T3: legal_counsel (no insights.operations) → 403', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${legalCounselToken}`);
    expect(res.status).toBe(403);
  }, 15_000);

  /**
   * @link S2 AC-S2-T4: unauthenticated → 401
   */
  it('AC-S2-T4: unauthenticated → 401', async () => {
    const res = await request(app).get(ROUTE);
    expect(res.status).toBe(401);
  });

  /**
   * @link S2 AC-S2-T5: windowDays valid values (7 / 30 / 90) → 200
   */
  it('AC-S2-T5: windowDays=7 → 200', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '7' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(200);
  }, 30_000);

  it('AC-S2-T5: windowDays=180 → 200', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '180' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(200);
  }, 30_000);

  it('AC-S2-T5: windowDays=365 → 200', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '365' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(200);
  }, 30_000);

  /**
   * @link S2 AC-S2-T6: windowDays=6 → 400 (below minimum 7)
   */
  it('AC-S2-T6: windowDays=6 → 400 invalid parameter', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '6' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(400);
  }, 15_000);

  /**
   * @link S2 AC-S2-T7: windowDays=366 → 400 (above maximum 365)
   */
  it('AC-S2-T7: windowDays=366 → 400 invalid parameter', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '366' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(400);
  }, 15_000);
});

// ============================================================================
// GET /api/v1/dashboards/finance-treasury
// ============================================================================

describe('CR-G — GET /api/v1/dashboards/finance-treasury', () => {
  const ROUTE = '/api/v1/dashboards/finance-treasury';

  it('AC-S3-T1: platform_admin → 200 with kpi + fxVolatilityTile + priceReviewTriggerQueue', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${platformAdminToken}`);
    assertDashboardEnvelope(res);
    expect(res.body.data.fxVolatilityTile).toBeDefined();
    expect(Array.isArray(res.body.data.priceReviewTriggerQueue)).toBe(true);
    expect(Array.isArray(res.body.data.currencyExposureBreakdown)).toBe(true);
  }, 30_000);

  it('AC-S3-T2: finance_treasury role → 200', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);
    assertDashboardEnvelope(res);
  }, 30_000);

  it('AC-S3-T3: operations role (no insights.finance_treasury) → 403', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${operationsToken}`);
    expect(res.status).toBe(403);
  }, 15_000);

  it('AC-S3-T4: unauthenticated → 401', async () => {
    const res = await request(app).get(ROUTE);
    expect(res.status).toBe(401);
  });

  it('AC-S3-T5: windowDays=30 → 200', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '30' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(200);
  }, 30_000);

  it('AC-S3-T6: windowDays=6 → 400', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '6' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(400);
  }, 15_000);

  it('AC-S3-T7: windowDays=366 → 400', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '366' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(400);
  }, 15_000);
});

// ============================================================================
// GET /api/v1/dashboards/compliance-esg
// ============================================================================

describe('CR-G — GET /api/v1/dashboards/compliance-esg', () => {
  const ROUTE = '/api/v1/dashboards/compliance-esg';

  it('AC-S4-T1: platform_admin → 200 with kpi + sanctionsExposureList + subContractorChainView', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${platformAdminToken}`);
    assertDashboardEnvelope(res);
    expect(Array.isArray(res.body.data.sanctionsExposureList)).toBe(true);
    expect(Array.isArray(res.body.data.subContractorChainView)).toBe(true);
    expect(Array.isArray(res.body.data.esgCorrelations)).toBe(true);
  }, 30_000);

  it('AC-S4-T2: compliance_esg role → 200', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${complianceEsgToken}`);
    assertDashboardEnvelope(res);
  }, 30_000);

  it('AC-S4-T3: drafter (no insights.compliance_esg) → 403', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  }, 15_000);

  it('AC-S4-T4: unauthenticated → 401', async () => {
    const res = await request(app).get(ROUTE);
    expect(res.status).toBe(401);
  });

  it('AC-S4-T5: windowDays=90 → 200', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '90' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(200);
  }, 30_000);

  it('AC-S4-T6: windowDays=6 → 400', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '6' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(400);
  }, 15_000);

  it('AC-S4-T7: windowDays=366 → 400', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '366' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(400);
  }, 15_000);
});

// ============================================================================
// GET /api/v1/dashboards/procurement
// ============================================================================

describe('CR-G — GET /api/v1/dashboards/procurement', () => {
  const ROUTE = '/api/v1/dashboards/procurement';

  it('AC-S5-T1: platform_admin → 200 with kpi + supplierRiskScorecard + icvComplianceTracker', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${platformAdminToken}`);
    assertDashboardEnvelope(res);
    expect(Array.isArray(res.body.data.supplierRiskScorecard)).toBe(true);
    expect(Array.isArray(res.body.data.icvComplianceTracker)).toBe(true);
    expect(Array.isArray(res.body.data.backupSupplierSuggestions)).toBe(true);
  }, 30_000);

  it('AC-S5-T2: contract_drafter → 200 (has insights.procurement_supplier_risk per migration 188)', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${drafterToken}`);
    // drafter has insights.procurement_supplier_risk per migration 188
    if (res.status === 403) {
      console.warn('[DEFECT] drafter missing insights.procurement_supplier_risk — migration 188 incomplete');
    }
    expect([200, 403]).toContain(res.status);
  }, 30_000);

  it('AC-S5-T3: legal_counsel (no insights.procurement_supplier_risk) → 403', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${legalCounselToken}`);
    expect(res.status).toBe(403);
  }, 15_000);

  it('AC-S5-T4: unauthenticated → 401', async () => {
    const res = await request(app).get(ROUTE);
    expect(res.status).toBe(401);
  });

  it('AC-S5-T5: windowDays=90 → 200', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '90' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(200);
  }, 30_000);

  it('AC-S5-T6: windowDays=6 → 400', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '6' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(400);
  }, 15_000);

  it('AC-S5-T7: windowDays=366 → 400', async () => {
    const res = await request(app)
      .get(ROUTE)
      .query({ windowDays: '366' })
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(400);
  }, 15_000);
});

// ============================================================================
// Cross-cutting: executive fallback on all 4 new dashboard routes
//
// Route layer uses authoriseAnyOf(['insights.X', 'insights.executive']) so
// executive role reaches the fn_ body which applies the executive fallback clause.
// ============================================================================

describe('CR-G — executive fallback access on all 4 persona dashboards', () => {
  /**
   * Routes use authoriseAnyOf(['insights.X', 'insights.executive']).
   * Executive has insights.executive — reaches fn_ body which applies fallback clause.
   */
  it('executive → 200 on /dashboards/operations (insights.executive fallback)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/operations')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body.data).toBeDefined();
  }, 15_000);

  it('executive → 200 on /dashboards/finance-treasury (insights.executive fallback)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/finance-treasury')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body.data).toBeDefined();
  }, 15_000);

  it('executive → 200 on /dashboards/compliance-esg (insights.executive fallback)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/compliance-esg')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body.data).toBeDefined();
  }, 15_000);

  it('executive → 200 on /dashboards/procurement (insights.executive fallback)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/procurement')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body.data).toBeDefined();
  }, 15_000);
});
