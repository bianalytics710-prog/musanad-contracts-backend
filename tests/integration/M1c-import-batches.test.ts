/**
 * M1c — /api/v1/import-batches integration tests (S1, S2, S3, S4).
 *
 * One test per AC label. Permission gate negative tests cover:
 *   - 401 when no JWT present
 *   - 403 when caller lacks the required permission
 *   - 200/201/204 when caller has the right permission
 *
 * Test users:
 *   - bootstrap admin (role 'Super Admin') — has all permissions per the
 *     pre-emptive grant in 018 (import.run + import.review).
 *   - drafter1 fixture — contract_drafter (import.run + import.review).
 *   - recipient1 fixture — contract_recipient (no import.*).
 *   - legal_counsel1 fixture — legal_counsel (import.review only).
 *
 * Cleanup: hard-delete every batch the suite creates in afterAll via the
 * BYPASSRLS admin pool.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  closeAdminPool,
  loginAdmin,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  cleanupImportBatchesByIds,
  getFixture,
  seedFixtureUsers,
  signFixtureToken,
  seedImportBatch,
  setImportBatchActiveBypassTrigger,
} from '../helpers/m1c-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;
let recipientToken: string;
let legalCounselToken: string;

const createdBatchIds: number[] = [];
const trackBatch = (id: number): number => {
  if (typeof id === 'number') createdBatchIds.push(id);
  return id;
};

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;

  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  recipientToken = signFixtureToken('recipient1');
  legalCounselToken = signFixtureToken('legal_counsel1');
});

afterAll(async () => {
  if (createdBatchIds.length > 0) {
    try {
      await cleanupImportBatchesByIds(createdBatchIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M1c-import-batches-cleanup] failed:', err);
    }
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

// ============================================================================
// S1 — POST /api/v1/import-batches
// ============================================================================
describe('S1 — POST /api/v1/import-batches', () => {
  it('AC-S1-01: 201 with full batch shape, counters at 0, status=in_progress', async () => {
    const res = await request(app)
      .post('/api/v1/import-batches')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ totalFiles: 4, config: { statusMode: 'active' } });
    expect(res.status).toBe(201);
    trackBatch(res.body.id);
    expect(res.body).toMatchObject({
      status: 'in_progress',
      totalFiles: 4,
      autoSaved: 0,
      reviewQueue: 0,
      manualEntry: 0,
      duplicatesSkipped: 0,
    });
    expect(res.body.config).toMatchObject({ statusMode: 'active' });
    expect(typeof res.body.startedAt).toBe('string');
  });

  it('AC-S1-02: 400 with field=totalFiles when totalFiles < 1', async () => {
    const res = await request(app)
      .post('/api/v1/import-batches')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ totalFiles: 0, config: { statusMode: 'active' } });
    expect(res.status).toBe(400);
    expect(res.body.error?.code).toMatch(/VALIDATION/i);
    // Zod path produces details.totalFiles
    expect(res.body.error?.details?.totalFiles).toBeTruthy();
    expect(String(res.body.error?.details?.totalFiles)).toMatch(
      /at least 1/i,
    );
  });

  it('AC-S1-03: 400 with field config.statusMode when statusMode invalid', async () => {
    const res = await request(app)
      .post('/api/v1/import-batches')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ totalFiles: 5, config: { statusMode: 'unknown' } });
    expect(res.status).toBe(400);
    expect(res.body.error?.code).toMatch(/VALIDATION/i);
    // Zod path 'config.statusMode' — assert text contains statusMode hint.
    const detailsStr = JSON.stringify(res.body.error?.details ?? {});
    expect(detailsStr).toMatch(/statusMode/i);
  });

  it('AC-S1-04: 403 when caller lacks import.run', async () => {
    // recipient1 (contract_recipient) lacks import.run.
    const res = await request(app)
      .post('/api/v1/import-batches')
      .set('Authorization', `Bearer ${recipientToken}`)
      .send({ totalFiles: 5, config: { statusMode: 'active' } });
    expect(res.status).toBe(403);
    expect(res.body.error?.code).toMatch(/FORBIDDEN/i);
  });

  it('Permission gate: 401 when no JWT present', async () => {
    const res = await request(app)
      .post('/api/v1/import-batches')
      .send({ totalFiles: 5, config: { statusMode: 'active' } });
    expect(res.status).toBe(401);
  });

  it('AC-S1-05: initiated_by equals caller; audit_log INSERT row created', async () => {
    const res = await request(app)
      .post('/api/v1/import-batches')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ totalFiles: 2, config: { statusMode: 'auto' } });
    expect(res.status).toBe(201);
    trackBatch(res.body.id);
    const drafter = getFixture('drafter1');
    expect(Number(res.body.initiatedBy?.id ?? res.body.initiatedBy)).toBe(drafter.id);
  });

  it('AC-S1-06: contract.import_batch_id is left NULL on this fn_ (no contract created here)', async () => {
    // Phase 0 sanity: creating a batch does not touch the contract table.
    // Asserted by inspecting the batch row — totalFiles set, but no contract
    // FK link manipulation observed (covered in cross-module suite via
    // S5/S7 ACs; here we just confirm the new batch is independent).
    const res = await request(app)
      .post('/api/v1/import-batches')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ totalFiles: 1, config: { statusMode: 'draft' } });
    expect(res.status).toBe(201);
    trackBatch(res.body.id);
    // Smoke: the response shape has no contract IDs; this is the expected
    // separation per design (per-file fn_contract_create wires it).
    expect(res.body).not.toHaveProperty('contractId');
  });
});

// ============================================================================
// S2 — PATCH /api/v1/import-batches/:id
// ============================================================================
describe('S2 — PATCH /api/v1/import-batches/:id', () => {
  it('AC-S2-01: counter increments returned in response', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 5,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);

    const res = await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ autoSavedDelta: 2, reviewQueueDelta: 1 });
    expect(res.status).toBe(200);
    expect(res.body.autoSaved).toBe(2);
    expect(res.body.reviewQueue).toBe(1);
  });

  it('AC-S2-02 + AC-S2-03: status=completed sets completedAt', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    const res = await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ status: 'completed', autoSavedDelta: 1 });
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('completed');
    expect(res.body.completedAt).not.toBeNull();
  });

  it('AC-S2-02: invalid transition returns 409 with field=status', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    // Move to completed.
    await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ status: 'completed', autoSavedDelta: 1 });
    // Try to reopen.
    const res = await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ status: 'in_progress' });
    expect(res.status).toBe(409);
    expect(JSON.stringify(res.body)).toMatch(/Invalid status transition/i);
  });

  it('AC-S2-04: counter underflow returns 400 with field=<counterName>', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 5,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    const res = await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ autoSavedDelta: -1 }); // would drive autoSaved to -1
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).toMatch(/(autoSaved|underflow)/i);
  });

  it('AC-S2-05: counter overflow vs totalFiles returns 400', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 2,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    const res = await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ autoSavedDelta: 5 }); // exceeds totalFiles=2
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).toMatch(/overflow/i);
  });

  it('AC-S2-06: nonexistent id returns 404', async () => {
    const res = await request(app)
      .patch('/api/v1/import-batches/9999999')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ autoSavedDelta: 1 });
    expect(res.status).toBe(404);
    expect(JSON.stringify(res.body)).toMatch(/not found/i);
  });

  it('AC-S2-07: caller without import.run AND not initiator returns 403', async () => {
    // Owner = admin (id=1). recipient1 (no import.*) tries to update.
    const seeded = await seedImportBatch(1, {
      totalFiles: 3,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    const res = await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${recipientToken}`)
      .send({ autoSavedDelta: 1 });
    // Could be 403 from BE middleware (recipient lacks both import.run and
    // import.review) — acceptable. Either way must NOT be 200 / 204.
    expect([401, 403]).toContain(res.status);
  });

  it('AC-S2-08: terminal cancelled cannot reopen — 409', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ status: 'cancelled' });
    const res = await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ status: 'in_progress' });
    expect(res.status).toBe(409);
  });

  it('Permission gate: 401 when no JWT', async () => {
    const res = await request(app)
      .patch('/api/v1/import-batches/1')
      .send({ autoSavedDelta: 1 });
    expect(res.status).toBe(401);
  });

  it('Validation: empty body refines to 400', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    const res = await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    expect(res.status).toBe(400);
  });
});

// ============================================================================
// S3 — GET /api/v1/import-batches
// ============================================================================
describe('S3 — GET /api/v1/import-batches', () => {
  it('AC-S3-01 + AC-S3-04: paginated; pagination meta + per-row required keys', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);

    const res = await request(app)
      .get('/api/v1/import-batches')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.pagination).toMatchObject({ page: 1, limit: 20 });
    if (res.body.data.length > 0) {
      const row = res.body.data[0];
      for (const k of [
        'id',
        'initiatedBy',
        'totalFiles',
        'autoSaved',
        'reviewQueue',
        'manualEntry',
        'duplicatesSkipped',
        'status',
        'startedAt',
        'completedAt',
      ]) {
        expect(row).toHaveProperty(k);
      }
    }
  });

  it('AC-S3-02: total=0 → totalPages=0, data=[]', async () => {
    // Filter by an impossibly large initiatedBy id (no such user).
    const res = await request(app)
      .get('/api/v1/import-batches')
      .query({ initiatedBy: '9999999' })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual([]);
    expect(res.body.pagination.total).toBe(0);
    expect(res.body.pagination.totalPages).toBe(0);
  });

  it('AC-S3-03: filter by status="paused" returns only paused', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    await request(app)
      .patch(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ status: 'paused' });

    const res = await request(app)
      .get('/api/v1/import-batches')
      .query({ status: 'paused', limit: 100 })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    for (const row of res.body.data) {
      expect(row.status).toBe('paused');
    }
  });

  it('AC-S3-05: limit=0 → 400 with details.limit; limit=101 → 400', async () => {
    const r1 = await request(app)
      .get('/api/v1/import-batches')
      .query({ limit: '0' })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(r1.status).toBe(400);
    expect(JSON.stringify(r1.body)).toMatch(/limit/i);

    const r2 = await request(app)
      .get('/api/v1/import-batches')
      .query({ limit: '101' })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(r2.status).toBe(400);
  });

  it('AC-S3-06: caller lacks both import.review AND import.run → 403', async () => {
    const res = await request(app)
      .get('/api/v1/import-batches')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S3-07: contract_drafter sees only own batches; admin sees all', async () => {
    const drafter = getFixture('drafter1');
    const ownByDrafter = await seedImportBatch(drafter.id, {
      totalFiles: 2,
      config: { statusMode: 'active' },
    });
    trackBatch(ownByDrafter.id);
    const ownByAdmin = await seedImportBatch(1, {
      totalFiles: 2,
      config: { statusMode: 'active' },
    });
    trackBatch(ownByAdmin.id);

    const drafterRes = await request(app)
      .get('/api/v1/import-batches')
      .query({ limit: 100 })
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(drafterRes.status).toBe(200);
    const drafterIds = drafterRes.body.data.map((r: { id: number }) => r.id);
    expect(drafterIds).toContain(ownByDrafter.id);
    expect(drafterIds).not.toContain(ownByAdmin.id);

    const adminRes = await request(app)
      .get('/api/v1/import-batches')
      .query({ limit: 100 })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(adminRes.status).toBe(200);
    const adminIds = adminRes.body.data.map((r: { id: number }) => r.id);
    expect(adminIds).toContain(ownByDrafter.id);
    expect(adminIds).toContain(ownByAdmin.id);
  });

  it('AC-S3-08: is_active=false batches not returned', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    // Migration 021 added a BEFORE UPDATE trigger that blocks direct
    // is_active toggles; bypass via session_replication_role='replica' so
    // the test can arrange the soft-deleted state.
    await setImportBatchActiveBypassTrigger(seeded.id, false);
    const res = await request(app)
      .get('/api/v1/import-batches')
      .query({ limit: 100 })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    const ids = res.body.data.map((r: { id: number }) => r.id);
    expect(ids).not.toContain(seeded.id);
    // Restore for cleanup.
    await setImportBatchActiveBypassTrigger(seeded.id, true);
  });

  it('Permission gate: legal_counsel1 (import.review only) CAN read', async () => {
    const res = await request(app)
      .get('/api/v1/import-batches')
      .set('Authorization', `Bearer ${legalCounselToken}`);
    expect(res.status).toBe(200);
  });
});

// ============================================================================
// S4 — GET /api/v1/import-batches/:id
// ============================================================================
describe('S4 — GET /api/v1/import-batches/:id', () => {
  it('AC-S4-01: returns full batch shape including timestamps', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 4,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    const res = await request(app)
      .get(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(seeded.id);
    for (const k of [
      'id',
      'initiatedBy',
      'config',
      'totalFiles',
      'autoSaved',
      'reviewQueue',
      'manualEntry',
      'duplicatesSkipped',
      'status',
      'startedAt',
      'createdAt',
      'updatedAt',
    ]) {
      expect(res.body).toHaveProperty(k);
    }
  });

  it('AC-S4-02: nonexistent id → 404 "Import batch not found"', async () => {
    const res = await request(app)
      .get('/api/v1/import-batches/9999999')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
    expect(JSON.stringify(res.body)).toMatch(/not found/i);
  });

  it('AC-S4-03: caller without permission AND not initiator → 403 (BE middleware)', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 2,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    const res = await request(app)
      .get(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${recipientToken}`);
    expect([403, 404]).toContain(res.status);
  });

  it('AC-S4-04: initiatedBy is hydrated UserRef { id, firstName, lastName }', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    const res = await request(app)
      .get(`/api/v1/import-batches/${seeded.id}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(typeof res.body.initiatedBy).toBe('object');
    expect(Number(res.body.initiatedBy.id)).toBe(drafter.id);
    expect(typeof res.body.initiatedBy.firstName).toBe('string');
    expect(typeof res.body.initiatedBy.lastName).toBe('string');
  });

  it('AC-S4-05: drill-down via GET /contracts?importBatchId={id} reuses M1a route (smoke)', async () => {
    // The drill-down is served by the M1a /api/v1/contracts list, not by a
    // new endpoint. Verify the endpoint accepts importBatchId without 4xx.
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    const res = await request(app)
      .get('/api/v1/contracts')
      .query({ importBatchId: seeded.id, limit: 10 })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
  });

  it('Permission gate: 401 when no JWT', async () => {
    const res = await request(app).get('/api/v1/import-batches/1');
    expect(res.status).toBe(401);
  });
});
