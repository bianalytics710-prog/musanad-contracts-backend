/**
 * M7 — admin/sources HTTP integration tests (CR-A).
 *
 * Covers the 9 M7 endpoints as seen by Express:
 *   GET    /api/v1/admin/sources                  (list)
 *   GET    /api/v1/admin/sources/:id              (get-by-id)
 *   POST   /api/v1/admin/sources                  (create)
 *   PATCH  /api/v1/admin/sources/:id              (update)
 *   DELETE /api/v1/admin/sources/:id              (delete soft)
 *   POST   /api/v1/admin/sources/:id/credential   (set credential)
 *   POST   /api/v1/admin/sources/:id/test-pull    (queue test pull)
 *   GET    /api/v1/admin/source-health            (health monitor)
 *   GET    /api/v1/signals                        (signal list)
 *
 * Asserts auth (401), permission (403), happy paths (200/201/202), DEF-1
 * (404 on unknown id), DEF-2 (409 on disabled source), and the AC-S3-04
 * invariant — credentialRef NEVER appears in any response shape.
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

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;
let legalToken: string;
let executiveToken: string;

const RUN_ID = `m7int-${Date.now()}`;
const createdSourceIds: number[] = [];

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;

  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  legalToken = signFixtureToken('legal_counsel1');
  executiveToken = signFixtureToken('executive1');

  // Sanity: fixture role names match expectations.
  expect(getFixture('drafter1').roleName).toBe('contract_drafter');
  expect(getFixture('legal_counsel1').roleName).toBe('legal_counsel');
  expect(getFixture('executive1').roleName).toBe('executive');
});

afterAll(async () => {
  if (createdSourceIds.length > 0) {
    try {
      await adminQuery(
        `DELETE FROM source_health WHERE osint_source_id = ANY($1::BIGINT[])`,
        [createdSourceIds],
      );
      await adminQuery(
        `DELETE FROM source_credential WHERE osint_source_id = ANY($1::BIGINT[])`,
        [createdSourceIds],
      );
      await adminQuery(
        `DELETE FROM osint_signal WHERE osint_source_id = ANY($1::BIGINT[])`,
        [createdSourceIds],
      );
      await adminQuery(
        `DELETE FROM osint_source WHERE id = ANY($1::BIGINT[])`,
        [createdSourceIds],
      );
    } catch (err) {
      console.warn('[M7-int-cleanup]', err);
    }
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

// ============================================================================
// Auth gate (401)
// ============================================================================

describe('M7 admin/sources — auth gate', () => {
  it('GET /api/v1/admin/sources without token → 401', async () => {
    const res = await request(app).get('/api/v1/admin/sources');
    expect(res.status).toBe(401);
  });

  it('POST /api/v1/admin/sources without token → 401', async () => {
    const res = await request(app).post('/api/v1/admin/sources').send({});
    expect(res.status).toBe(401);
  });

  it('GET /api/v1/admin/source-health without token → 401', async () => {
    const res = await request(app).get('/api/v1/admin/source-health');
    expect(res.status).toBe(401);
  });

  it('GET /api/v1/signals without token → 401', async () => {
    const res = await request(app).get('/api/v1/signals');
    expect(res.status).toBe(401);
  });
});

// ============================================================================
// Permission gating (AC-S8-06, AC-S11-05)
// ============================================================================

describe('M7 admin/sources — permission gating', () => {
  it('AC-S8-06: drafter (no source.read) GET /admin/sources → 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/sources')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S8-06: drafter GET /admin/source-health → 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/source-health')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S11-05 design exception: drafter has contract.edit → GET /signals → 200 (NOTE-1 carve-out)', async () => {
    const res = await request(app)
      .get('/api/v1/signals')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(200);
  });

  it('legal_counsel (no source.read) GET /admin/sources → 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/sources')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(403);
  });

  it('legal_counsel GET /signals → 200', async () => {
    const res = await request(app)
      .get('/api/v1/signals')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toBeDefined();
    expect(Array.isArray(res.body.data)).toBe(true);
  });

  it('executive (has source.read) GET /admin/source-health → 200 (bare array)', async () => {
    const res = await request(app)
      .get('/api/v1/admin/source-health')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
  });
});

// ============================================================================
// Happy-path CRUD (Super Admin token)
// ============================================================================

describe('M7 admin/sources — CRUD happy path', () => {
  let createdId: number;

  it('GET /admin/sources → 200 with paginated envelope including ADNOC seed sources', async () => {
    const res = await request(app)
      .get('/api/v1/admin/sources?limit=100')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toBeDefined();
    expect(Array.isArray(res.body.data)).toBe(true);
    // 13 ADNOC seed rows (smoke verified). Allow >= for prior test sources.
    expect(res.body.data.length).toBeGreaterThanOrEqual(13);
    expect(res.body.pagination).toBeDefined();
    // AC-S3-04 invariant: no credentialRef in any list row.
    for (const row of res.body.data) {
      expect(row).not.toHaveProperty('credentialRef');
      expect(row).not.toHaveProperty('credential_ref');
    }
  });

  it('POST /admin/sources → 201 with created row', async () => {
    const res = await request(app)
      .post('/api/v1/admin/sources')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        sourceId: `m7int_create_${RUN_ID}`,
        displayName: 'M7 integration create',
        kind: 'news',
        format: 'rss',
        refreshSeconds: 900,
        sourceReliability: 0.85,
      });
    expect(res.status).toBe(201);
    expect(typeof res.body.id).toBe('number');
    expect(res.body.sourceId).toBe(`m7int_create_${RUN_ID}`);
    expect(res.body).not.toHaveProperty('credentialRef');
    createdId = res.body.id;
    createdSourceIds.push(createdId);
  });

  it('GET /admin/sources/:id → 200 (no credentialRef in response)', async () => {
    const res = await request(app)
      .get(`/api/v1/admin/sources/${createdId}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(createdId);
    // AC-S3-04 invariant — credential metadata only includes kind + lastRotatedAt
    if (res.body.credential !== null && res.body.credential !== undefined) {
      expect(res.body.credential).not.toHaveProperty('credentialRef');
      expect(res.body.credential).not.toHaveProperty('credential_ref');
    }
  });

  it('PATCH /admin/sources/:id → 200 with updated displayName', async () => {
    const res = await request(app)
      .patch(`/api/v1/admin/sources/${createdId}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ displayName: `M7 updated ${RUN_ID}` });
    expect(res.status).toBe(200);
    expect(res.body.displayName).toBe(`M7 updated ${RUN_ID}`);
  });

  it('AC-S3-08: PATCH with sourceId in body → 400', async () => {
    const res = await request(app)
      .patch(`/api/v1/admin/sources/${createdId}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ sourceId: 'attempt_to_change' });
    expect(res.status).toBe(400);
  });

  it('AC-S3-04 / AC-S3-05: POST /credential succeeds, response excludes credentialRef', async () => {
    const res = await request(app)
      .post(`/api/v1/admin/sources/${createdId}/credential`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ credentialKind: 'api_key', credentialRef: 'env:M7_INTEGRATION_TEST_KEY' });
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('credentialKind', 'api_key');
    expect(res.body).toHaveProperty('lastRotatedAt');
    expect(res.body).not.toHaveProperty('credentialRef');
    expect(res.body).not.toHaveProperty('credential_ref');
  });

  it('AC-S3-06: POST /credential with plain-text scheme → 400', async () => {
    const res = await request(app)
      .post(`/api/v1/admin/sources/${createdId}/credential`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ credentialKind: 'api_key', credentialRef: 'sk-rawSecretValue123' });
    expect(res.status).toBe(400);
  });

  it('AC-S3-07: DELETE /admin/sources/:id → 200 (soft delete)', async () => {
    const res = await request(app)
      .delete(`/api/v1/admin/sources/${createdId}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.deactivated).toBe(true);

    // DB confirms soft state.
    const rows = await adminQuery<{ is_active: boolean; enabled: boolean }>(
      `SELECT is_active, enabled FROM osint_source WHERE id = $1`, [createdId],
    );
    expect(rows[0]!.is_active).toBe(false);
    expect(rows[0]!.enabled).toBe(false);
  });
});

// ============================================================================
// DEF-1 + DEF-2 regression — translatePgError 22023 routing
// ============================================================================

describe('M7 admin/sources — translatePgError DEF-1 + DEF-2 regression', () => {
  it('DEF-1: GET /admin/sources/:id with unknown id → 404', async () => {
    const res = await request(app)
      .get('/api/v1/admin/sources/99999999')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
  });

  it('DEF-1: PATCH /admin/sources/:id with unknown id → 404', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/sources/99999999')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ displayName: 'Should not work' });
    expect(res.status).toBe(404);
  });

  it('DEF-1: DELETE /admin/sources/:id with unknown id → 404', async () => {
    const res = await request(app)
      .delete('/api/v1/admin/sources/99999999')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
  });

  it('DEF-2: POST /test-pull on disabled source → 409', async () => {
    // Create a source with enabled=false.
    const create = await request(app)
      .post('/api/v1/admin/sources')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        sourceId: `m7int_disabled_${RUN_ID}`,
        displayName: 'disabled test',
        kind: 'news',
        format: 'rss',
        refreshSeconds: 900,
        sourceReliability: 0.85,
        enabled: false,
      });
    expect(create.status).toBe(201);
    createdSourceIds.push(create.body.id);

    const res = await request(app)
      .post(`/api/v1/admin/sources/${create.body.id}/test-pull`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(409);
  });

  it('AC-S7-06: POST /test-pull on enabled source → 202', async () => {
    // Use the ADNOC seed source ofac_sdn (enabled by default)
    const seed = await adminQuery<{ id: number }>(
      `SELECT id FROM osint_source WHERE source_id = 'ofac_sdn' AND tenant_id = '00000000-0000-0000-0000-000000000001'`,
    );
    expect(seed.length).toBe(1);
    const res = await request(app)
      .post(`/api/v1/admin/sources/${seed[0]!.id}/test-pull`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(202);
    expect(res.body.queued).toBe(true);
    expect(res.body.sourceId).toBe('ofac_sdn');
    expect(res.body.requestedAt).toBeDefined();
  });
});

// ============================================================================
// /signals filtering (AC-S11-01..03)
// ============================================================================

describe('M7 GET /signals — filters + pagination', () => {
  it('AC-S11-01: returns paginated envelope', async () => {
    const res = await request(app)
      .get('/api/v1/signals?limit=5')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.pagination).toBeDefined();
    expect(typeof res.body.pagination.total).toBe('number');
    expect(typeof res.body.pagination.totalPages).toBe('number');
  });

  it('AC-S11-03: pagination metadata present even on empty result', async () => {
    const res = await request(app)
      .get('/api/v1/signals?since=2099-01-01T00:00:00Z')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual([]);
    expect(res.body.pagination.total).toBe(0);
    expect(res.body.pagination.totalPages).toBe(0);
  });

  it('rejects invalid kind enum with 400', async () => {
    const res = await request(app)
      .get('/api/v1/signals?kind=nope')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(400);
  });
});
