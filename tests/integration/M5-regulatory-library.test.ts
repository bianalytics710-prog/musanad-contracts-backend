/**
 * M5 — Regulatory Library tests for S1..S5.
 *
 * Surfaces:
 *   - GET    /api/v1/regulations            (S1, fn_regulation_list)
 *   - GET    /api/v1/regulations/:id        (S2, fn_regulation_get_by_id)
 *   - POST   /api/v1/regulations            (S3, fn_regulation_create)
 *   - PATCH  /api/v1/regulations/:id        (S4, fn_regulation_update)
 *   - DELETE /api/v1/regulations/:id        (S5, fn_regulation_delete)
 *
 * Strategy: live Express app + supertest for HTTP-level shape; direct
 * callFnAs for fn-body permission negatives (broad route gate would short-
 * circuit them at HTTP layer — fn-body 42501 / 23503 / etc. need the
 * BYPASSRLS pool with app.current_user_id set).
 *
 * Fixture users from m1c-helpers (drafter1, recipient1, executive1,
 * legal_counsel1) + the bootstrap admin (Super Admin).
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
import { callFnAs } from '../helpers/m2-helpers';
import {
  cleanupRegulatoryArtifacts,
  getRegulatorIdByCode,
  readRegulationById,
  seedRegulation,
  seedRegulatoryImpact,
  tagFor,
} from '../helpers/m5-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;
let recipientToken: string;
let legalToken: string;
let executiveToken: string;

let mohreId: number;

const createdRegulationIds: number[] = [];
const createdImpactIds: number[] = [];
const SUITE_TAG = tagFor('reg-lib');

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
  executiveToken = signFixtureToken('executive1');

  mohreId = await getRegulatorIdByCode('MoHRE');
});

afterAll(async () => {
  try {
    await cleanupRegulatoryArtifacts({
      regulatoryImpactIds: createdImpactIds,
      regulationIds: createdRegulationIds,
    });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M5-reg-library cleanup]', err);
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

// Convenience — produce a unique referenceCode per call so UNIQUE doesn't trip.
const refCode = (suffix: string): string =>
  `${SUITE_TAG}-${suffix}-${Math.floor(Math.random() * 1e9)}`.slice(0, 78);

// ============================================================================
// S1 — GET /api/v1/regulations
// ============================================================================
describe('S1 — fn_regulation_list / GET /api/v1/regulations', () => {
  it('AC-S1-01: returns paginated envelope with { data, pagination }', async () => {
    // Seed at least one row so 'data' has content
    const id = await seedRegulation({
      referenceCode: refCode('s1-01'),
      titleEn: `${SUITE_TAG} S1-01`,
      issuerId: mohreId,
      regulationType: 'circular',
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);

    const res = await request(app)
      .get('/api/v1/regulations')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ limit: 5 });

    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.pagination).toBeDefined();
    expect(res.body.pagination).toHaveProperty('total');
    expect(res.body.pagination).toHaveProperty('page');
    expect(res.body.pagination).toHaveProperty('limit');
    expect(res.body.pagination).toHaveProperty('totalPages');
  });

  it('AC-S1-02: jurisdiction filter narrows results', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s1-02'),
      titleEn: `${SUITE_TAG} S1-02 jurisdiction`,
      issuerId: mohreId,
      jurisdiction: 'difc',
      regulationType: 'guideline',
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);

    const res = await request(app)
      .get('/api/v1/regulations')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ jurisdiction: 'difc', limit: 50 });

    expect(res.status).toBe(200);
    // every row returned must match the filter
    for (const row of res.body.data as Array<{ jurisdiction?: string }>) {
      expect(row.jurisdiction).toBe('difc');
    }
  });

  it('AC-S1-04: returns empty data array (HTTP 200) when no regulations match', async () => {
    const res = await request(app)
      .get('/api/v1/regulations')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ search: 'no-match-xyz-' + Date.now() });
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual([]);
  });

  it('AC-S1-05: soft-deleted regulations are hidden from default list', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s1-05'),
      titleEn: `${SUITE_TAG} S1-05 soft-del`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);
    // Soft-delete via fn (via admin who is platform_admin/Super Admin).
    await callFnAs<unknown>(admin.user.id, 'fn_regulation_delete', [id, admin.user.id]);

    const res = await request(app)
      .get('/api/v1/regulations')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ limit: 200 });
    expect(res.status).toBe(200);
    const ids = (res.body.data as Array<{ id: number }>).map((r) => r.id);
    expect(ids).not.toContain(id);
  });

  it('AC-S1-06: contract_recipient receives 403 (no regulations.read)', async () => {
    const res = await request(app)
      .get('/api/v1/regulations')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });
});

// ============================================================================
// S2 — GET /api/v1/regulations/:id
// ============================================================================
describe('S2 — fn_regulation_get_by_id / GET /api/v1/regulations/:id', () => {
  it('AC-S2-01: returns full regulation row', async () => {
    const refc = refCode('s2-01');
    const id = await seedRegulation({
      referenceCode: refc,
      titleEn: `${SUITE_TAG} S2-01`,
      titleAr: 'تنظيم تجريبي',
      issuerId: mohreId,
      regulationType: 'cabinet_resolution',
      jurisdiction: 'uae_federal',
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);

    const res = await request(app)
      .get(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toBeDefined();
    // The fn returns a flattened row; assert key fields exist.
    expect(res.body.id ?? res.body.regulation?.id).toBeDefined();
  });

  it('AC-S2-03: returns 404 with field=id when id does not exist', async () => {
    const res = await request(app)
      .get('/api/v1/regulations/999999999')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
  });

  it('AC-S2-03: returns 404 when regulation is soft-deleted (is_active=FALSE)', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s2-03'),
      titleEn: `${SUITE_TAG} S2-03 deleted`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);
    await callFnAs<unknown>(admin.user.id, 'fn_regulation_delete', [id, admin.user.id]);

    const res = await request(app)
      .get(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
  });
});

// ============================================================================
// S3 — POST /api/v1/regulations
// ============================================================================
describe('S3 — fn_regulation_create / POST /api/v1/regulations', () => {
  it('AC-S3-01: legal_counsel can create with valid input — returns 201', async () => {
    const refc = refCode('s3-01');
    const res = await request(app)
      .post('/api/v1/regulations')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        referenceCode: refc,
        titleEn: `${SUITE_TAG} S3-01`,
        issuerId: mohreId,
        regulationType: 'circular',
      });
    expect(res.status).toBe(201);
    // fn returns the freshly-fetched row via fn_regulation_get_by_id; id present.
    expect(res.body).toBeDefined();
    if (res.body.id) {
      createdRegulationIds.push(Number(res.body.id));
    }
  });

  it('AC-S3-02: duplicate referenceCode returns 409', async () => {
    const refc = refCode('s3-02');
    const idA = await seedRegulation({
      referenceCode: refc,
      titleEn: `${SUITE_TAG} S3-02 first`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(idA);
    const res = await request(app)
      .post('/api/v1/regulations')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        referenceCode: refc,
        titleEn: `${SUITE_TAG} S3-02 dup`,
        issuerId: mohreId,
        regulationType: 'circular',
      });
    expect(res.status).toBe(409);
  });

  it('AC-S3-03: missing titleEn returns 400 with field=titleEn', async () => {
    const res = await request(app)
      .post('/api/v1/regulations')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        referenceCode: refCode('s3-03'),
        issuerId: mohreId,
        regulationType: 'circular',
      });
    expect(res.status).toBe(400);
    // either zod 'titleEn' field details or fn 23502 message — accept either
    const body = JSON.stringify(res.body).toLowerCase();
    expect(body).toContain('titleen');
  });

  it('AC-S3-04: invalid regulationType returns 400', async () => {
    const res = await request(app)
      .post('/api/v1/regulations')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        referenceCode: refCode('s3-04'),
        titleEn: `${SUITE_TAG} S3-04`,
        issuerId: mohreId,
        regulationType: 'not_a_real_type',
      });
    expect(res.status).toBe(400);
  });

  it('AC-S3-05: contract_drafter (no regulations.manage) receives 403', async () => {
    const res = await request(app)
      .post('/api/v1/regulations')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        referenceCode: refCode('s3-05'),
        titleEn: `${SUITE_TAG} S3-05`,
        issuerId: mohreId,
        regulationType: 'circular',
      });
    expect(res.status).toBe(403);
  });

  it('AC-S3-06: status defaults to active when not supplied', async () => {
    const res = await request(app)
      .post('/api/v1/regulations')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        referenceCode: refCode('s3-06'),
        titleEn: `${SUITE_TAG} S3-06 default-status`,
        issuerId: mohreId,
        regulationType: 'circular',
      });
    expect(res.status).toBe(201);
    const id = Number(res.body.id);
    createdRegulationIds.push(id);
    const row = await readRegulationById(id);
    expect(row).not.toBeNull();
    expect(row!['status']).toBe('active');
  });
});

// ============================================================================
// S4 — PATCH /api/v1/regulations/:id
// ============================================================================
describe('S4 — fn_regulation_update / PATCH /api/v1/regulations/:id', () => {
  it('AC-S4-01: legal_counsel patches a single field', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s4-01'),
      titleEn: `${SUITE_TAG} S4-01 before`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);

    const res = await request(app)
      .patch(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ titleEn: `${SUITE_TAG} S4-01 after` });
    expect(res.status).toBe(200);
    const row = await readRegulationById(id);
    expect(row!['title_en']).toBe(`${SUITE_TAG} S4-01 after`);
  });

  it('AC-S4-02: setting supersededById auto-flips status to superseded', async () => {
    const refA = refCode('s4-02-a');
    const refB = refCode('s4-02-b');
    const idA = await seedRegulation({
      referenceCode: refA,
      titleEn: `${SUITE_TAG} S4-02 A`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    const idB = await seedRegulation({
      referenceCode: refB,
      titleEn: `${SUITE_TAG} S4-02 B`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(idA, idB);

    const res = await request(app)
      .patch(`/api/v1/regulations/${idA}`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ supersededById: idB });
    expect(res.status).toBe(200);
    const row = await readRegulationById(idA);
    expect(row!['status']).toBe('superseded');
    expect(Number(row!['superseded_by_id'])).toBe(idB);
  });

  it('AC-S4-03: self-supersede returns 400 with supersededById message', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s4-03'),
      titleEn: `${SUITE_TAG} S4-03`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);

    const res = await request(app)
      .patch(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ supersededById: id });
    expect(res.status).toBe(400);
    const body = JSON.stringify(res.body).toLowerCase();
    expect(body).toContain('supersededbyid');
  });

  it('AC-S4-04: supersededById pointing to non-existent regulation returns 400', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s4-04'),
      titleEn: `${SUITE_TAG} S4-04`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);
    const res = await request(app)
      .patch(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ supersededById: 999_999_999 });
    expect(res.status).toBe(400);
  });

  it('AC-S4-05: patching referenceCode is rejected (immutable; 23501 → 400)', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s4-05'),
      titleEn: `${SUITE_TAG} S4-05`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);
    const res = await request(app)
      .patch(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${legalToken}`)
      // .strict() Zod schema rejects unknown keys with 400 — both paths are
      // valid AC-S4-05 satisfaction; just assert 400.
      .send({ referenceCode: 'NEW-CODE' });
    expect(res.status).toBe(400);
  });

  it('AC-S4-06: returns 404 when id not found', async () => {
    const res = await request(app)
      .patch('/api/v1/regulations/999999999')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ titleEn: 'whatever' });
    expect(res.status).toBe(404);
  });

  it('AC-S4-07: contract_drafter without regulations.manage receives 403', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s4-07'),
      titleEn: `${SUITE_TAG} S4-07`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);
    const res = await request(app)
      .patch(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ titleEn: 'denied' });
    expect(res.status).toBe(403);
  });
});

// ============================================================================
// S5 — DELETE /api/v1/regulations/:id  (the 23503 disambiguator path)
// ============================================================================
describe('S5 — fn_regulation_delete / DELETE /api/v1/regulations/:id', () => {
  it('AC-S5-01: platform_admin (Super Admin) soft-deletes a regulation with no impacts', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s5-01'),
      titleEn: `${SUITE_TAG} S5-01`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);

    const res = await request(app)
      .delete(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.id).toBeDefined();
    expect(res.body.isActive).toBe(false);
    const row = await readRegulationById(id);
    expect(row!['is_active']).toBe(false);
    expect(row!['status']).toBe('repealed');
  });

  it('AC-S5-02: refuses with 409 when active impacts reference the regulation', async () => {
    // Seed regulation + a contract via direct admin INSERT then attach an impact row
    const regId = await seedRegulation({
      referenceCode: refCode('s5-02'),
      titleEn: `${SUITE_TAG} S5-02 with-impact`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(regId);

    // Create a contract via the HTTP API for FK on regulatory_impact.contract_id
    const c = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        titleEn: `${SUITE_TAG}-S5-02 contract`,
        contractType: 'employment',
        language: 'en',
      });
    expect(c.status).toBe(201);
    const contractId = Number(c.body.id);

    // Attach a structural impact (no regulatory_update — exercises NULL path)
    const impactId = await seedRegulatoryImpact({
      contractId,
      regulationId: regId,
      regulatoryUpdateId: null,
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(impactId);

    const res = await request(app)
      .delete(`/api/v1/regulations/${regId}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(409);
    const body = JSON.stringify(res.body).toLowerCase();
    expect(body).toContain('regulationid');
    expect(body).toContain('cannot delete');

    // Cleanup the contract — defer to global afterAll-style by passing it through cleanupContractsByIds
    const { cleanupContractsByIds } = await import('../helpers/m1a-helpers');
    // First nuke the impact (FK to contract)
    await cleanupRegulatoryArtifacts({ regulatoryImpactIds: [impactId] });
    await cleanupContractsByIds([contractId]);
    // remove from tracking so afterAll doesn't re-delete the impact
    createdImpactIds.splice(createdImpactIds.indexOf(impactId), 1);
  });

  it('AC-S5-03: returns 404 when id not found', async () => {
    const res = await request(app)
      .delete('/api/v1/regulations/999999999')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
  });

  it('AC-S5-04: legal_counsel cannot delete (platform_admin gate; 403)', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s5-04'),
      titleEn: `${SUITE_TAG} S5-04 legal-denied`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);
    const res = await request(app)
      .delete(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S5-05: soft-deleted rows do not appear in fn_regulation_list', async () => {
    const id = await seedRegulation({
      referenceCode: refCode('s5-05'),
      titleEn: `${SUITE_TAG} S5-05`,
      issuerId: mohreId,
      actorUserId: admin.user.id,
    });
    createdRegulationIds.push(id);
    await request(app)
      .delete(`/api/v1/regulations/${id}`)
      .set('Authorization', `Bearer ${adminToken}`);

    const res = await request(app)
      .get('/api/v1/regulations')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ limit: 200 });
    expect(res.status).toBe(200);
    const ids = (res.body.data as Array<{ id: number }>).map((r) => r.id);
    expect(ids).not.toContain(id);
  });
});

// ============================================================================
// Cross-cutting — executive read access (AC-S1 implicit / role matrix)
// ============================================================================
describe('M5 cross-cutting — executive role can list regulations', () => {
  it('executive (regulations.read) can list', async () => {
    const res = await request(app)
      .get('/api/v1/regulations')
      .set('Authorization', `Bearer ${executiveToken}`)
      .query({ limit: 5 });
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
  });
});
