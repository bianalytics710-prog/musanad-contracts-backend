/**
 * M5 — Regulatory Radar tests for S6..S10.
 *
 * Surfaces:
 *   - GET    /api/v1/regulatory-updates             (S6, fn_regulatory_update_list)
 *   - GET    /api/v1/regulatory-updates/:id         (S7, fn_regulatory_update_get_by_id)
 *   - POST   /api/v1/regulatory-updates             (S8, fn_regulatory_update_create)
 *   - PATCH  /api/v1/regulatory-updates/:id         (S9, fn_regulatory_update_update)
 *   - DELETE /api/v1/regulatory-updates/:id         (S10, fn_regulatory_update_delete — cascade)
 *
 * Special focus:
 *   - S9 AC-S9-02 publishedDate floor — cannot push below MIN(detected_at) of impacts
 *   - S10 AC-S10-02 cascade-soft-delete to regulatory_impact rows tied only to that update
 *     (structural impacts with regulatory_update_id IS NULL untouched)
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  cleanupContractsByIds,
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
  cleanupRegulatoryArtifacts,
  getImpactCategoryIdByKey,
  getRegulatorIdByCode,
  readRegulatoryImpactById,
  readRegulatoryUpdateById,
  seedRegulation,
  seedRegulatoryImpact,
  seedRegulatoryUpdate,
  tagFor,
} from '../helpers/m5-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;
let recipientToken: string;
let legalToken: string;

let mohreId: number;
let labourCatId: number | null;

const createdUpdateIds: number[] = [];
const createdRegulationIds: number[] = [];
const createdImpactIds: number[] = [];
const createdContractIds: number[] = [];
const SUITE_TAG = tagFor('reg-radar');

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;
  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  recipientToken = signFixtureToken('recipient1');
  legalToken = signFixtureToken('legal_counsel1');

  mohreId = await getRegulatorIdByCode('MoHRE');
  labourCatId = await getImpactCategoryIdByKey('labour');
});

afterAll(async () => {
  try {
    await cleanupRegulatoryArtifacts({
      regulatoryImpactIds: createdImpactIds,
      regulatoryUpdateIds: createdUpdateIds,
      regulationIds: createdRegulationIds,
      contractIds: createdContractIds,
    });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M5-reg-radar cleanup]', err);
  }
  try {
    if (createdContractIds.length > 0) {
      await cleanupContractsByIds(createdContractIds);
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M5-reg-radar contract cleanup]', err);
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

const todayIso = (offsetDays = 0): string => {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + offsetDays);
  return d.toISOString().slice(0, 10);
};

const createDraftContract = async (token: string): Promise<number> => {
  const res = await request(app)
    .post('/api/v1/contracts')
    .set('Authorization', `Bearer ${token}`)
    .send({
      titleEn: `${SUITE_TAG}-c-${Date.now()}-${Math.floor(Math.random() * 1e9)}`,
      contractType: 'employment',
      language: 'en',
    });
  expect(res.status).toBe(201);
  const id = Number(res.body.id);
  createdContractIds.push(id);
  return id;
};

// ============================================================================
// S6 — GET /api/v1/regulatory-updates
// ============================================================================
describe('S6 — fn_regulatory_update_list / GET /api/v1/regulatory-updates', () => {
  it('AC-S6-01: returns paginated envelope { data, pagination }', async () => {
    const id = await seedRegulatoryUpdate({
      regulatorId: mohreId,
      titleEn: `${SUITE_TAG} S6-01`,
      publishedDate: todayIso(-30),
      severity: 'medium',
      categoryId: labourCatId,
      actorUserId: admin.user.id,
    });
    createdUpdateIds.push(id);

    const res = await request(app)
      .get('/api/v1/regulatory-updates')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ limit: 10 });
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.pagination).toBeDefined();
  });

  it('AC-S6-02: severity filter narrows results', async () => {
    const id = await seedRegulatoryUpdate({
      regulatorId: mohreId,
      titleEn: `${SUITE_TAG} S6-02 critical`,
      publishedDate: todayIso(-15),
      severity: 'critical',
      categoryId: labourCatId,
      actorUserId: admin.user.id,
    });
    createdUpdateIds.push(id);

    const res = await request(app)
      .get('/api/v1/regulatory-updates')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ severity: 'critical', limit: 50 });
    expect(res.status).toBe(200);
    for (const row of res.body.data as Array<{ severity?: string }>) {
      expect(row.severity).toBe('critical');
    }
  });

  it('AC-S6-11: contract_recipient receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/regulatory-updates')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });
});

// ============================================================================
// S7 — GET /api/v1/regulatory-updates/:id
// ============================================================================
describe('S7 — fn_regulatory_update_get_by_id / GET /api/v1/regulatory-updates/:id', () => {
  it('AC-S7-01 / AC-S7-02: returns row with impactSummary aggregate', async () => {
    const id = await seedRegulatoryUpdate({
      regulatorId: mohreId,
      titleEn: `${SUITE_TAG} S7-01`,
      publishedDate: todayIso(-7),
      severity: 'high',
      categoryId: labourCatId,
      actorUserId: admin.user.id,
    });
    createdUpdateIds.push(id);

    const res = await request(app)
      .get(`/api/v1/regulatory-updates/${id}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toBeDefined();
    expect(res.body.impactSummary).toBeDefined();
    // AC-S7-04 — empty impact set ⇒ avgImpactScore null AND zero counts
    expect(res.body.impactSummary.totalImpacts ?? 0).toBe(0);
  });

  it('AC-S7-04: avgImpactScore is null when totalImpacts is zero', async () => {
    const id = await seedRegulatoryUpdate({
      regulatorId: mohreId,
      titleEn: `${SUITE_TAG} S7-04`,
      publishedDate: todayIso(-7),
      severity: 'low',
      actorUserId: admin.user.id,
    });
    createdUpdateIds.push(id);
    const res = await request(app)
      .get(`/api/v1/regulatory-updates/${id}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.impactSummary.avgImpactScore).toBeNull();
  });

  it('AC-S7-03: returns 404 when id not found', async () => {
    const res = await request(app)
      .get('/api/v1/regulatory-updates/999999999')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
  });
});

// ============================================================================
// S8 — POST /api/v1/regulatory-updates
// ============================================================================
describe('S8 — fn_regulatory_update_create / POST /api/v1/regulatory-updates', () => {
  it('AC-S8-01: legal_counsel creates valid update — returns 201', async () => {
    const res = await request(app)
      .post('/api/v1/regulatory-updates')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatorId: mohreId,
        titleEn: `${SUITE_TAG} S8-01`,
        publishedDate: todayIso(-5),
        severity: 'medium',
      });
    expect(res.status).toBe(201);
    if (res.body.id) {
      createdUpdateIds.push(Number(res.body.id));
    }
  });

  it('AC-S8-02: invalid severity returns 400', async () => {
    const res = await request(app)
      .post('/api/v1/regulatory-updates')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatorId: mohreId,
        titleEn: `${SUITE_TAG} S8-02`,
        publishedDate: todayIso(-1),
        severity: 'super-mega',
      });
    expect(res.status).toBe(400);
  });

  it('AC-S8-03: effectiveDate < publishedDate returns 400', async () => {
    const res = await request(app)
      .post('/api/v1/regulatory-updates')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatorId: mohreId,
        titleEn: `${SUITE_TAG} S8-03`,
        publishedDate: todayIso(0),
        effectiveDate: todayIso(-10),
      });
    expect(res.status).toBe(400);
    const body = JSON.stringify(res.body).toLowerCase();
    expect(body).toContain('effectivedate');
  });

  it('AC-S8-04: complianceDeadline < publishedDate returns 400', async () => {
    const res = await request(app)
      .post('/api/v1/regulatory-updates')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatorId: mohreId,
        titleEn: `${SUITE_TAG} S8-04`,
        publishedDate: todayIso(0),
        complianceDeadline: todayIso(-5),
      });
    expect(res.status).toBe(400);
  });

  it('AC-S8-06: contract_drafter (no regulations.manage) receives 403', async () => {
    const res = await request(app)
      .post('/api/v1/regulatory-updates')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        regulatorId: mohreId,
        titleEn: `${SUITE_TAG} S8-06 denied`,
        publishedDate: todayIso(-1),
      });
    expect(res.status).toBe(403);
  });

  it('AC-S8-07: severity defaults to medium', async () => {
    const res = await request(app)
      .post('/api/v1/regulatory-updates')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatorId: mohreId,
        titleEn: `${SUITE_TAG} S8-07 default-severity`,
        publishedDate: todayIso(-2),
      });
    expect(res.status).toBe(201);
    const id = Number(res.body.id);
    createdUpdateIds.push(id);
    const row = await readRegulatoryUpdateById(id);
    expect(row!['severity']).toBe('medium');
  });
});

// ============================================================================
// S9 — PATCH /api/v1/regulatory-updates/:id  (publishedDate floor guard)
// ============================================================================
describe('S9 — fn_regulatory_update_update / PATCH /api/v1/regulatory-updates/:id', () => {
  it('AC-S9-01: legal_counsel patches a single field', async () => {
    const id = await seedRegulatoryUpdate({
      regulatorId: mohreId,
      titleEn: `${SUITE_TAG} S9-01 before`,
      publishedDate: todayIso(-30),
      actorUserId: admin.user.id,
    });
    createdUpdateIds.push(id);

    const res = await request(app)
      .patch(`/api/v1/regulatory-updates/${id}`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ titleEn: `${SUITE_TAG} S9-01 after` });
    expect(res.status).toBe(200);
    const row = await readRegulatoryUpdateById(id);
    expect(row!['title_en']).toBe(`${SUITE_TAG} S9-01 after`);
  });

  it('AC-S9-02: cannot move publishedDate below MIN(detected_at) of associated impacts', async () => {
    // 1. Create an update with publishedDate = T-30
    const updateId = await seedRegulatoryUpdate({
      regulatorId: mohreId,
      titleEn: `${SUITE_TAG} S9-02`,
      publishedDate: todayIso(-30),
      actorUserId: admin.user.id,
    });
    createdUpdateIds.push(updateId);
    // 2. Create a regulation + a contract + an impact tied to update
    const regId = await seedRegulation({
      referenceCode: `${SUITE_TAG}-S9-02-${Math.floor(Math.random() * 1e9)}`,
      titleEn: `${SUITE_TAG} S9-02 reg`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(regId);
    const contractId = await createDraftContract(adminToken);
    const impactId = await seedRegulatoryImpact({
      contractId,
      regulationId: regId,
      regulatoryUpdateId: updateId,
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(impactId);

    // 3. Try to move publishedDate to FUTURE day (after detected_at = NOW) ⇒ should reject
    const res = await request(app)
      .patch(`/api/v1/regulatory-updates/${updateId}`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ publishedDate: todayIso(7) });
    expect(res.status).toBe(400);
    const body = JSON.stringify(res.body).toLowerCase();
    expect(body).toContain('publisheddate');
  });

  it('AC-S9-03: returns 404 when id not found', async () => {
    const res = await request(app)
      .patch('/api/v1/regulatory-updates/999999999')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ titleEn: 'no-such' });
    expect(res.status).toBe(404);
  });

  it('AC-S9-04: contract_drafter (no regulations.manage) receives 403', async () => {
    const id = await seedRegulatoryUpdate({
      regulatorId: mohreId,
      titleEn: `${SUITE_TAG} S9-04`,
      publishedDate: todayIso(-1),
      actorUserId: admin.user.id,
    });
    createdUpdateIds.push(id);
    const res = await request(app)
      .patch(`/api/v1/regulatory-updates/${id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ titleEn: 'denied' });
    expect(res.status).toBe(403);
  });
});

// ============================================================================
// S10 — DELETE /api/v1/regulatory-updates/:id  (cascade soft-delete)
// ============================================================================
describe('S10 — fn_regulatory_update_delete / DELETE /api/v1/regulatory-updates/:id', () => {
  it('AC-S10-01 + AC-S10-02: cascades to impacts tied to this update; structural impacts untouched', async () => {
    // Setup:
    //   regulatoryUpdate U
    //   regulation R
    //   contract C1, C2, C3
    //   impact I1 (regulatory_update_id = U)  → must be soft-deleted
    //   impact I2 (regulatory_update_id = U)  → must be soft-deleted
    //   impact I3 (regulatory_update_id = NULL — structural) → must NOT be touched
    const updateId = await seedRegulatoryUpdate({
      regulatorId: mohreId,
      titleEn: `${SUITE_TAG} S10-01`,
      publishedDate: todayIso(-30),
      actorUserId: admin.user.id,
    });
    createdUpdateIds.push(updateId);
    const regId = await seedRegulation({
      referenceCode: `${SUITE_TAG}-S10-${Math.floor(Math.random() * 1e9)}`,
      titleEn: `${SUITE_TAG} S10 reg`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(regId);
    const c1 = await createDraftContract(adminToken);
    const c2 = await createDraftContract(adminToken);
    const c3 = await createDraftContract(adminToken);

    const i1 = await seedRegulatoryImpact({
      contractId: c1,
      regulationId: regId,
      regulatoryUpdateId: updateId,
      actorUserId: admin.user.id,
    });
    const i2 = await seedRegulatoryImpact({
      contractId: c2,
      regulationId: regId,
      regulatoryUpdateId: updateId,
      actorUserId: admin.user.id,
    });
    const i3 = await seedRegulatoryImpact({
      contractId: c3,
      regulationId: regId,
      regulatoryUpdateId: null, // structural
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(i1, i2, i3);

    const res = await request(app)
      .delete(`/api/v1/regulatory-updates/${updateId}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.id).toBeDefined();
    expect(res.body.isActive).toBe(false);
    expect(res.body.cascadedImpacts).toBe(2);

    // Verify per-row state
    const u = await readRegulatoryUpdateById(updateId);
    expect(u!['is_active']).toBe(false);
    const r1 = await readRegulatoryImpactById(i1);
    const r2 = await readRegulatoryImpactById(i2);
    const r3 = await readRegulatoryImpactById(i3);
    expect(r1!['is_active']).toBe(false);
    expect(r2!['is_active']).toBe(false);
    // The structural impact (regulatory_update_id IS NULL) is preserved
    expect(r3!['is_active']).toBe(true);
  });

  it('AC-S10-03: returns 404 when id not found', async () => {
    const res = await request(app)
      .delete('/api/v1/regulatory-updates/999999999')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
  });

  it('AC-S10-04: legal_counsel cannot delete (platform_admin gate; 403)', async () => {
    const id = await seedRegulatoryUpdate({
      regulatorId: mohreId,
      titleEn: `${SUITE_TAG} S10-04`,
      publishedDate: todayIso(-1),
      actorUserId: admin.user.id,
    });
    createdUpdateIds.push(id);
    const res = await request(app)
      .delete(`/api/v1/regulatory-updates/${id}`)
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(403);
  });
});
