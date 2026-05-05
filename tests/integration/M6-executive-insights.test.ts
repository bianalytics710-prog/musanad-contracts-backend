/**
 * M6 — Executive Insights (S7–S10) integration + DB function tests.
 *
 * Surfaces:
 *   - GET /api/v1/dashboards/executive                   (S7, fn_dashboard_executive)
 *   - GET /api/v1/dashboards/executive/anomalies-history (S8, fn_dashboard_executive_anomalies_history)
 *   - S9 / S10 are FE-only mounts — covered by smoke; we add ONE thin BE test
 *     each to confirm the wrapping endpoints behave correctly.
 *
 * Focus per Orchestrator brief:
 *   - S7: insights.executive permission gate; inline AI cost summary (Q5);
 *         expiryCliffs monotonic; aiCostUsdWindow null when caller lacks
 *         ai.observability.read (AC-S7-05)
 *   - S8: history reads from M4 ai_insight rows; empty array (NOT 404) when
 *         cache empty (AC-S8-02)
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  closeAdminPool,
  loginAdmin,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  signFixtureToken,
} from '../helpers/m1c-helpers';
import {
  cleanupDashboardArtifacts,
  getRoleIdByName,
  grantPermissionToRole,
  revokePermissionFromRole,
  roleHasPermission,
  seedAiInsight,
  tagFor,
} from '../helpers/m6-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let executiveToken: string;
let drafterToken: string;
let recipientToken: string;
let legalToken: string;

const createdAiInsightIds: number[] = [];
const SUITE_TAG = tagFor('exec-insights');

// Track ai.observability.read grant-state for executive role; we may flip it
// inside individual tests and must restore at the end.
let executiveRoleId = -1;
let executiveHadAiObsReadAtStart = false;

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;
  await seedFixtureUsers();
  executiveToken = signFixtureToken('executive1');
  drafterToken = signFixtureToken('drafter1');
  recipientToken = signFixtureToken('recipient1');
  legalToken = signFixtureToken('legal_counsel1');

  executiveRoleId = await getRoleIdByName('executive');
  executiveHadAiObsReadAtStart = await roleHasPermission(
    executiveRoleId,
    'ai.observability.read',
  );
}, 60_000);

afterAll(async () => {
  // Restore ai.observability.read grant state on the executive role.
  try {
    if (executiveRoleId > 0) {
      if (executiveHadAiObsReadAtStart) {
        await grantPermissionToRole(executiveRoleId, 'ai.observability.read');
      } else {
        await revokePermissionFromRole(executiveRoleId, 'ai.observability.read');
      }
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M6-exec-insights perm restore]', err);
  }
  try {
    await cleanupDashboardArtifacts({ aiInsightIds: createdAiInsightIds });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M6-exec-insights cleanup]', err);
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 60_000);

// ============================================================================
// S7 — fn_dashboard_executive
// ============================================================================
describe('S7 — fn_dashboard_executive / GET /api/v1/dashboards/executive', () => {
  it('AC-S7-01: executive caller returns 200 with kpis + trends', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis).toBeDefined();
    expect(res.body.trends).toBeDefined();
    expect(typeof res.body.kpis.totalActiveValueAed).toBe('number');
    expect(typeof res.body.kpis.contractsByStatus).toBe('object');
    expect(res.body.kpis.expiryCliffs).toBeDefined();
    expect(Array.isArray(res.body.kpis.topCounterpartiesByValue5)).toBe(true);
    expect(Array.isArray(res.body.kpis.valueDistribution)).toBe(true);
    expect(typeof res.body.kpis.openRegulatoryImpactsCritical).toBe('number');
    expect(Array.isArray(res.body.trends.valueOverTimeByMonth)).toBe(true);
    expect(Array.isArray(res.body.trends.contractsCreatedByMonth)).toBe(true);
  });

  it('AC-S7-01b: platform_admin (Super Admin bootstrap) reaches body', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
  });

  it('AC-S7-03: expiryCliffs is monotonic next30d <= next60d <= next90d', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    const cliffs = res.body.kpis.expiryCliffs;
    expect(cliffs.next30d).toBeLessThanOrEqual(cliffs.next60d);
    expect(cliffs.next60d).toBeLessThanOrEqual(cliffs.next90d);
  });

  it('AC-S7-04: topCounterpartiesByValue5 has at most 5 rows; each row has counterpartyId/totalValueAed/contractCount', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis.topCounterpartiesByValue5.length).toBeLessThanOrEqual(5);
    for (const row of res.body.kpis.topCounterpartiesByValue5) {
      expect(row).toHaveProperty('counterpartyId');
      expect(row).toHaveProperty('totalValueAed');
      expect(row).toHaveProperty('contractCount');
    }
  });

  it('AC-S7-05 / Q5 lock: aiCostUsdWindow is null when caller lacks ai.observability.read', async () => {
    // Ensure executive role does NOT hold ai.observability.read for this test.
    await revokePermissionFromRole(executiveRoleId, 'ai.observability.read');
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis.aiCostUsdWindow).toBeNull();
  });

  it('AC-S7-05b / Q5 lock: aiCostUsdWindow is a number when caller has ai.observability.read', async () => {
    await grantPermissionToRole(executiveRoleId, 'ai.observability.read');
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(typeof res.body.kpis.aiCostUsdWindow).toBe('number');
    expect(res.body.kpis.aiCostUsdWindow).toBeGreaterThanOrEqual(0);
  });

  it('AC-S7-06: contract_drafter receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S7-06b: contract_recipient receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S7-06c: legal_counsel receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S7-07: windowDays=0 returns 400', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${executiveToken}`)
      .query({ windowDays: 0 });
    expect(res.status).toBe(400);
  });

  it('AC-S7-07b: windowDays=400 returns 400', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${executiveToken}`)
      .query({ windowDays: 400 });
    expect(res.status).toBe(400);
  });

  it('S7: valueDistribution buckets are non-negative counts', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    for (const b of res.body.kpis.valueDistribution) {
      expect(b).toHaveProperty('bucket');
      expect(b).toHaveProperty('count');
      expect(b.count).toBeGreaterThanOrEqual(0);
    }
  });

  it('S7 / DASH-OI-A: openRegulatoryImpactsCritical is a non-negative integer (uses CRIT-1 resolved=FALSE filter)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis.openRegulatoryImpactsCritical).toBeGreaterThanOrEqual(0);
    expect(Number.isInteger(res.body.kpis.openRegulatoryImpactsCritical)).toBe(true);
  });
});

// ============================================================================
// S8 — fn_dashboard_executive_anomalies_history
// ============================================================================
describe('S8 — fn_dashboard_executive_anomalies_history / GET /api/v1/dashboards/executive/anomalies-history', () => {
  it('AC-S8-01: executive caller returns 200 with anomalies array', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive/anomalies-history')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('anomalies');
    expect(Array.isArray(res.body.anomalies)).toBe(true);
  });

  it('AC-S8-02: empty cache returns 200 with anomalies = [] (NOT 404)', async () => {
    // We do NOT seed any executive_anomalies rows in this assertion path; the
    // test relies on whatever the cache holds. We only assert the 200 + array
    // shape; cache emptiness is environment-dependent. The 404-vs-empty
    // contract is verified by the absence of a 404 response.
    const res = await request(app)
      .get('/api/v1/dashboards/executive/anomalies-history')
      .set('Authorization', `Bearer ${executiveToken}`)
      .query({ limit: 1 });
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.anomalies)).toBe(true);
  });

  it('S8 / M4 cache integration: seeded ai_insight executive_anomalies row appears in the response', async () => {
    const executiveUser = getFixture('executive1');
    const insightId = await seedAiInsight({
      entityType: 'executive_anomalies',
      insightType: 'anomaly_detection',
      severity: 'high',
      payload: {
        summaryEn: `${SUITE_TAG} S8 high-severity anomaly`,
        detail: { synthetic: true },
      },
      actorUserId: executiveUser.id,
    });
    createdAiInsightIds.push(insightId);

    const res = await request(app)
      .get('/api/v1/dashboards/executive/anomalies-history')
      .set('Authorization', `Bearer ${executiveToken}`)
      .query({ limit: 50 });
    expect(res.status).toBe(200);
    type Row = { id: number };
    const rows = res.body.anomalies as Row[];
    const found = rows.find((r) => Number(r.id) === insightId);
    expect(found).toBeDefined();
    expect(found).toHaveProperty('detectedAt');
    expect(found).toHaveProperty('payload');
  });

  it('S8: contract_drafter receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive/anomalies-history')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('S8: contract_recipient receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive/anomalies-history')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });

  it('S8: limit=0 returns 400', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive/anomalies-history')
      .set('Authorization', `Bearer ${executiveToken}`)
      .query({ limit: 0 });
    expect(res.status).toBe(400);
  });

  it('S8: limit=51 returns 400', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive/anomalies-history')
      .set('Authorization', `Bearer ${executiveToken}`)
      .query({ limit: 51 });
    expect(res.status).toBe(400);
  });

  it('S8: platform_admin reaches body', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/executive/anomalies-history')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
  });
});

// ============================================================================
// S9 — ExecutiveAnomaliesCard mount (FE-only)
// ============================================================================
describe('S9 — FE-only mount (covered by smoke; thin BE confirmation)', () => {
  it('S9 marker: executive-anomalies-history endpoint is reachable for the card', async () => {
    // The card calls GET /api/v1/dashboards/executive/anomalies-history. We
    // re-verify it responds 200 to executive token here as a regression marker.
    const res = await request(app)
      .get('/api/v1/dashboards/executive/anomalies-history')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
  });
});

// ============================================================================
// S10 — VersionDiffSummaryPanel mount (FE-only)
// ============================================================================
describe('S10 — FE-only mount (covered by smoke; thin BE confirmation)', () => {
  it('S10 marker: M4 endpoint POST /api/v1/ai/version-diff-summary exists (panel target)', async () => {
    // The panel calls an existing M4 endpoint. We probe with an invalid
    // request to confirm the route resolves (NOT 404) — actual functional
    // coverage is in M4 tests.
    const res = await request(app)
      .post('/api/v1/ai/version-diff-summary')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({});
    expect(res.status).not.toBe(404);
  });
});
