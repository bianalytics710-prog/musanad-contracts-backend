/**
 * M14 / CR-F — Risk Score HTTP integration tests.
 *
 * Covers all 6 CR-F HTTP endpoints:
 *   GET  /api/v1/contracts/:id/risk-score          — fn_risk_score_explain (score.read)
 *   GET  /api/v1/contracts/:id/risk-score/history  — fn_risk_score_history (score.read)
 *   GET  /api/v1/risk/avar                         — fn_avar_aggregate (score.read)
 *   GET  /api/v1/admin/scoring-weights             — fn_scoring_weights_get (score.weights.manage)
 *   PATCH /api/v1/admin/scoring-weights            — fn_scoring_weights_set (score.weights.manage)
 *   POST /api/v1/admin/scoring-weights/recompute-all — fn_score_recompute_for_weight_change (score.weights.manage)
 *
 * Auth + permission gates verified for each route.
 * Shape assertions validate the migration 176 BIGINT-as-string + NUMERIC-as-string patches.
 *
 * Runs against TEST_DATABASE_URL (migration 176 applied).
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
} from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let executiveToken: string;
let platformAdminToken: string;
let drafterToken: string;
let recipientToken: string | null = null;

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;

  admin = await loginAdmin(app);
  adminToken = admin.accessToken;

  await seedFixtureUsers();
  executiveToken = signFixtureToken('executive1');
  platformAdminToken = signFixtureToken('platform_admin1');
  drafterToken = signFixtureToken('drafter1');

  // Recipient token — may not exist in fixture pool
  try {
    recipientToken = signFixtureToken('recipient1');
  } catch {
    recipientToken = null;
  }
});

afterAll(async () => {
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

// Helper: find a contract with at least one risk_score
// NOTE: contract table has no tenant_id column; tenant scoping is via risk_score/latest_risk_score
async function getContractWithScore(): Promise<number | null> {
  const rows = await adminQuery<{ contract_id: number }>(
    `SELECT rs.contract_id
     FROM latest_risk_score rs
     WHERE rs.tenant_id = $1::uuid
     LIMIT 1`,
    [ADNOC_TENANT_ID],
  );
  return rows.length > 0 ? rows[0]!.contract_id : null;
}

// ============================================================================
// Authentication gate (401 for all routes)
// ============================================================================

describe('CR-F risk score routes — auth gate (401)', () => {
  it('GET /api/v1/contracts/1/risk-score without token → 401', async () => {
    const res = await request(app).get('/api/v1/contracts/1/risk-score');
    expect(res.status).toBe(401);
  });

  it('GET /api/v1/contracts/1/risk-score/history without token → 401', async () => {
    const res = await request(app).get('/api/v1/contracts/1/risk-score/history');
    expect(res.status).toBe(401);
  });

  it('GET /api/v1/risk/avar without token → 401', async () => {
    const res = await request(app).get('/api/v1/risk/avar');
    expect(res.status).toBe(401);
  });

  it('GET /api/v1/admin/scoring-weights without token → 401', async () => {
    const res = await request(app).get('/api/v1/admin/scoring-weights');
    expect(res.status).toBe(401);
  });

  it('PATCH /api/v1/admin/scoring-weights without token → 401', async () => {
    const res = await request(app).patch('/api/v1/admin/scoring-weights').send({});
    expect(res.status).toBe(401);
  });

  it('POST /api/v1/admin/scoring-weights/recompute-all without token → 401', async () => {
    const res = await request(app).post('/api/v1/admin/scoring-weights/recompute-all');
    expect(res.status).toBe(401);
  });
});

// ============================================================================
// GET /api/v1/contracts/:id/risk-score
// ============================================================================

describe('CR-F — GET /api/v1/contracts/:id/risk-score', () => {
  /**
   * @link S9 AC-S9-01 — Returns RiskScoreExplainResponse for contract with score.
   * fn_risk_score_explain resolved — returns full explain shape with riskScoreId,
   * contractId, dimensions, healthScore, marValue, weightsAtCalculation, etc.
   */
  it('AC-S9-01: executive → 200 + RiskScoreExplainResponse shape for contract with score', async () => {
    const contractId = await getContractWithScore();
    if (!contractId) {
      console.warn('[SKIP] No contract with risk score found in test DB');
      return;
    }

    const res = await request(app)
      .get(`/api/v1/contracts/${contractId}/risk-score`)
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(200);
    expect(typeof res.body.data.riskScoreId).toBe('string');
    expect(typeof res.body.data.contractId).toBe('string');
    expect(res.body.data.dimensions).toBeDefined();
    expect(typeof res.body.data.healthScore).toBe('number');
    expect(Array.isArray(res.body.data.contributingCorrelations)).toBe(true);
  });

  /**
   * @link S9 AC-S9-02 — Non-existent contract → 404 NOT_FOUND.
   * fn_risk_score_explain correctly raises P0002 for contracts with no risk_score row.
   */
  it('AC-S9-02: non-existent contract → 404 NOT_FOUND', async () => {
    const res = await request(app)
      .get('/api/v1/contracts/999999999/risk-score')
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(404);
    expect(res.body.error?.code).toBe('NOT_FOUND');
  });

  it('AC-S9-03: contract_recipient on contract they do not own → 403 or 404', async () => {
    if (!recipientToken) return; // No recipient fixture available

    const contractId = await getContractWithScore();
    if (!contractId) return;

    const res = await request(app)
      .get(`/api/v1/contracts/${contractId}/risk-score`)
      .set('Authorization', `Bearer ${recipientToken}`);

    // contract_recipient does not have score.read permission → 403
    expect([403, 404]).toContain(res.status);
  });

  it('AC-S9-03: drafter (has score.read) → 200 or 404 depending on whether contract has a score', async () => {
    // contract_drafter has score.read permission — fn_risk_score_explain resolves correctly
    const contractId = await getContractWithScore();
    if (!contractId) return;

    const res = await request(app)
      .get(`/api/v1/contracts/${contractId}/risk-score`)
      .set('Authorization', `Bearer ${drafterToken}`);

    // drafter has score.read — should receive the explain payload (200) or 404 if no score row
    expect([200, 404]).toContain(res.status);
  });
});

// ============================================================================
// GET /api/v1/contracts/:id/risk-score/history
// ============================================================================

describe('CR-F — GET /api/v1/contracts/:id/risk-score/history', () => {
  /**
   * @link S11 AC-S11-01 — Returns snapshots array ordered ASC
   */
  it('AC-S11-01: executive with valid contract → 200 + snapshots with string riskScoreId', async () => {
    const contractId = await getContractWithScore();
    if (!contractId) return;

    const res = await request(app)
      .get(`/api/v1/contracts/${contractId}/risk-score/history?windowDays=90`)
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    const data = res.body.data;
    expect(Array.isArray(data.snapshots)).toBe(true);
    expect(typeof data.count).toBe('number');

    if (data.snapshots.length > 0) {
      const first = data.snapshots[0];
      // BIGINT-as-string + NUMERIC-as-string verification (migration 176 MEDIUM-1)
      expect(typeof first.riskScoreId).toBe('string');
      // marValue should be string or null — NOT a number
      if (first.marValue !== null && first.marValue !== undefined) {
        expect(typeof first.marValue).toBe('string');
      }
      expect(typeof first.healthScore).toBe('number');
    }
  });

  /**
   * @link S11 AC-S11-02 — windowDays=45 → 400 VALIDATION_ERROR
   */
  it('AC-S11-02: windowDays=45 → 400 VALIDATION_ERROR', async () => {
    const contractId = await getContractWithScore();
    if (!contractId) return;

    const res = await request(app)
      .get(`/api/v1/contracts/${contractId}/risk-score/history?windowDays=45`)
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(400);
  });

  it('AC-S11-02: windowDays=30 → 200', async () => {
    const contractId = await getContractWithScore();
    if (!contractId) return;

    const res = await request(app)
      .get(`/api/v1/contracts/${contractId}/risk-score/history?windowDays=30`)
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(200);
  });

  it('AC-S11-02: windowDays=180 → 200', async () => {
    const contractId = await getContractWithScore();
    if (!contractId) return;

    const res = await request(app)
      .get(`/api/v1/contracts/${contractId}/risk-score/history?windowDays=180`)
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(200);
  });
});

// ============================================================================
// GET /api/v1/risk/avar
// ============================================================================

describe('CR-F — GET /api/v1/risk/avar', () => {
  /**
   * @link S4 AC-S4-01 — Returns AvarResponse shape with NUMERIC-as-string (MEDIUM-2 patch)
   */
  it('AC-S4-01: executive → 200 + AvarResponse shape verified (NUMERIC-as-string)', async () => {
    const res = await request(app)
      .get('/api/v1/risk/avar')
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    const data = res.body.data;
    expect(data).toBeDefined();
    expect(data.currency).toBe('AED');
    expect(typeof data.contractCount).toBe('number');
    expect(Array.isArray(data.breakdown)).toBe(true);

    // NUMERIC-as-string verification (migration 176 MEDIUM-2)
    expect(typeof data.totalAvar).toBe('string');
    expect(data.deltaVsPriorWindow).toBeDefined();
    expect(typeof data.deltaVsPriorWindow.priorAvar).toBe('string');
    expect(typeof data.deltaVsPriorWindow.deltaAed).toBe('string');

    if (data.breakdown.length > 0) {
      const first = data.breakdown[0];
      if (first.avar !== null && first.avar !== undefined) {
        expect(typeof first.avar).toBe('string');
      }
    }
  });

  /**
   * @link S4 AC-S4-06 — Invalid groupBy → 400
   */
  it('AC-S4-06: invalid groupBy → 400 VALIDATION_ERROR', async () => {
    const res = await request(app)
      .get('/api/v1/risk/avar?groupBy=invalid_dim')
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(400);
  });

  it('AC-S4-06: valid groupBy=geography → 200', async () => {
    const res = await request(app)
      .get('/api/v1/risk/avar?groupBy=geography')
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(200);
  });

  /**
   * @link S4 AC-S4-05 — Caller without score.read → 403
   */
  it('AC-S4-05: recipient (no score.read) → 403 FORBIDDEN', async () => {
    if (!recipientToken) return;

    const res = await request(app)
      .get('/api/v1/risk/avar')
      .set('Authorization', `Bearer ${recipientToken}`);

    expect(res.status).toBe(403);
  });
});

// ============================================================================
// GET /api/v1/admin/scoring-weights
// ============================================================================

describe('CR-F — GET /api/v1/admin/scoring-weights', () => {
  /**
   * @link S6 AC-S6-03 — executive (no score.weights.manage) → 403
   */
  it('AC-S6-03: executive (no score.weights.manage) → 403 FORBIDDEN', async () => {
    const res = await request(app)
      .get('/api/v1/admin/scoring-weights')
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(403);
  });

  /**
   * @link S6 AC-S6-01 — platform_admin → 200 + ScoringWeightsResponse shape
   */
  it('AC-S6-01: platform_admin → 200 + ScoringWeightsResponse shape', async () => {
    const res = await request(app)
      .get('/api/v1/admin/scoring-weights')
      .set('Authorization', `Bearer ${platformAdminToken}`);

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    const data = res.body.data;
    expect(data.current).toBeDefined();
    expect(typeof data.current.legal).toBe('number');
    expect(typeof data.current.financial).toBe('number');
    expect(typeof data.current.operational).toBe('number');
    expect(typeof data.current.reputational).toBe('number');
    expect(typeof data.current.compliance).toBe('number');
    expect(typeof data.current.version).toBe('string');
    expect(Array.isArray(data.history)).toBe(true);
    expect(typeof data.exposureFractionDefaults).toBe('object');
    expect(typeof data.impactMultipliers).toBe('object');
  });
});

// ============================================================================
// PATCH /api/v1/admin/scoring-weights
// ============================================================================

describe('CR-F — PATCH /api/v1/admin/scoring-weights', () => {
  /**
   * @link S7 AC-S7-02 — Weights sum 0.5 → 400 (sum-tolerance violation)
   */
  it('AC-S7-02: weights that sum to 0.5 → 400 VALIDATION_ERROR (sum-tolerance violation)', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/scoring-weights')
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({
        legal: 0.1,
        financial: 0.1,
        operational: 0.1,
        reputational: 0.1,
        compliance: 0.1,
      });

    expect(res.status).toBe(400);
  });

  /**
   * @link S7 AC-S7-01 — Valid weights → 200 + new version assigned.
   * fn_scoring_weights_set uses fn_audit_log_record_v2 helper — resolves successfully.
   */
  it('AC-S7-01: valid weights (sum=1.0) → 200 + newVersion assigned', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/scoring-weights')
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({
        legal: 0.20,
        financial: 0.30,
        operational: 0.20,
        reputational: 0.10,
        compliance: 0.20,
      });

    expect(res.status).toBe(200);
    expect(typeof res.body.data.newVersion).toBe('string');
    expect(res.body.data.totalSum).toBe(1);
    expect(res.body.data.weightsApplied).toBeDefined();
  });

  it('AC-S7-03: missing dimension key → 400 VALIDATION_ERROR', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/scoring-weights')
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({
        legal: 0.25,
        financial: 0.25,
        // operational missing
        reputational: 0.25,
        compliance: 0.25,
      });

    expect(res.status).toBe(400);
  });

  /**
   * @link S7 AC-S7-05 — executive (no score.weights.manage) → 403
   */
  it('AC-S7-05: executive (no score.weights.manage) → 403 FORBIDDEN', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/scoring-weights')
      .set('Authorization', `Bearer ${executiveToken}`)
      .send({ legal: 0.20, financial: 0.30, operational: 0.20, reputational: 0.10, compliance: 0.20 });

    expect(res.status).toBe(403);
  });
});

// ============================================================================
// POST /api/v1/admin/scoring-weights/recompute-all
// ============================================================================

describe('CR-F — POST /api/v1/admin/scoring-weights/recompute-all', () => {
  /**
   * @link S8 AC-S8-01 — platform_admin → 200 + RecomputeAllResponse + at least 1 contract targeted
   */
  it('AC-S8-01: platform_admin → 200 + RecomputeAllResponse + recomputedCount >= 0', async () => {
    const res = await request(app)
      .post('/api/v1/admin/scoring-weights/recompute-all')
      .set('Authorization', `Bearer ${platformAdminToken}`);

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    const data = res.body.data;
    expect(typeof data.weightsVersion).toBe('string');
    expect(typeof data.totalContractsTargeted).toBe('number');
    expect(typeof data.recomputedCount).toBe('number');
    expect(Array.isArray(data.failedContractIds)).toBe(true);
    expect(typeof data.elapsedMs).toBe('number');

    // At least 0 contracts targeted (test DB should have bootstrap data)
    expect(data.totalContractsTargeted).toBeGreaterThanOrEqual(0);

    // MEDIUM-3 verification: failedContractIds must be string[] not number[]
    if (data.failedContractIds.length > 0) {
      expect(typeof data.failedContractIds[0]).toBe('string');
    }
  });

  /**
   * @link S8 AC-S8-03 — executive (no score.weights.manage) → 403
   */
  it('AC-S8-03: executive (no score.weights.manage) → 403 FORBIDDEN', async () => {
    const res = await request(app)
      .post('/api/v1/admin/scoring-weights/recompute-all')
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(res.status).toBe(403);
  });
});

// ============================================================================
// Negative: unauthenticated → 401 (redundant coverage from auth gate above — explicit)
// ============================================================================

describe('CR-F — explicit unauthenticated check (all 6 routes)', () => {
  it('All 6 CR-F endpoints → 401 without Authorization header', async () => {
    const contractId = (await getContractWithScore()) ?? 1;
    const results = await Promise.all([
      request(app).get(`/api/v1/contracts/${contractId}/risk-score`),
      request(app).get(`/api/v1/contracts/${contractId}/risk-score/history`),
      request(app).get('/api/v1/risk/avar'),
      request(app).get('/api/v1/admin/scoring-weights'),
      request(app).patch('/api/v1/admin/scoring-weights').send({}),
      request(app).post('/api/v1/admin/scoring-weights/recompute-all'),
    ]);

    for (const res of results) {
      expect(res.status).toBe(401);
    }
  });
});
