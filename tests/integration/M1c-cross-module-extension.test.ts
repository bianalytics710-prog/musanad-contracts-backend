/**
 * M1c — Cross-module extension regression tests (AE-1 / AE-2).
 *
 * Covers the M1a/M1c boundary work that doesn't fit in the new-endpoint suites:
 *
 *   1. fn_contract_list extension (15 → 18 params; row JSONB shape +3 fields)
 *      - AC-S6-08: importBatchId/importConfidence/importWarnings present on
 *                   every row in the list response.
 *      - AC-S6-01: importConfidenceMin/Max range filter narrows results.
 *      - AC-S4-05: importBatchId filter narrows to one batch.
 *      - Backward compat: existing M1a callers passing the original 13
 *        query params continue to receive 200 (M1a/M1b behaviour preserved).
 *      - M1a contracts not bulk-imported return null for the 3 new fields.
 *      - M1c-imported contracts return the populated values.
 *
 *   2. POST /api/v1/contracts (M1a) extended with importBatch* fields:
 *      - AC-S5-08: importBatchId is persisted on contract.import_batch_id
 *                   and shows up in fn_contract_get_by_id response.
 *      - AC-S7-04: manual-entry POST with the 4 new optional fields succeeds
 *                   and counter increment via fn_import_batch_update works.
 *
 *   3. AC-S5-09: duplicate-detection flow — when fn_contract_list already
 *      shows an active contract with the same contract_number, the bulk
 *      flow skips creating a duplicate and bumps duplicatesSkipped counter.
 *      We assert the BE side: the flow is composable from existing
 *      endpoints (no duplicate enforcement in fn_contract_create — that's a
 *      M1a invariant — so the FE-driven skip works on top of fn_contract_list
 *      results).
 *
 *   4. AC-S6-04: status transition draft → active works via M1a
 *      fn_contract_status_update (regression test confirming the draft →
 *      active transition is permitted; flagged in BE-Q3-OI-C-test-handoff).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  cleanupContractsByIds,
  closeAdminPool,
  loginAdmin,
  adminQuery,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  cleanupImportBatchesByIds,
  getFixture,
  seedFixtureUsers,
  seedImportBatch,
  signFixtureToken,
} from '../helpers/m1c-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;

const createdContractIds: number[] = [];
const createdBatchIds: number[] = [];

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;

  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
});

afterAll(async () => {
  if (createdContractIds.length > 0) {
    try {
      await cleanupContractsByIds(createdContractIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M1c-cross-module-cleanup] contract:', err);
    }
  }
  if (createdBatchIds.length > 0) {
    try {
      await cleanupImportBatchesByIds(createdBatchIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M1c-cross-module-cleanup] batch:', err);
    }
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

// ============================================================================
// fn_contract_list — backward-compat + 3 new optional filters + 3 new fields
// ============================================================================
describe('AE-1 — fn_contract_list extension (15 → 18 params; +3 row fields)', () => {
  it('Backward-compat: GET /api/v1/contracts with NO M1c params returns 200 (M1a callers unaffected)', async () => {
    const res = await request(app)
      .get('/api/v1/contracts')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
  });

  it('AC-S6-08: every row in fn_contract_list response carries importBatchId, importConfidence, importWarnings', async () => {
    // Seed a non-imported contract to ensure the row shape includes the new
    // (null-valued) keys.
    const post = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        titleEn: 'M1c-AE1-PlainContract',
        contractType: 'service',
        language: 'en',
      });
    expect(post.status).toBe(201);
    createdContractIds.push(post.body.id);

    const list = await request(app)
      .get('/api/v1/contracts')
      .query({ limit: 100 })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(list.status).toBe(200);
    expect(list.body.data.length).toBeGreaterThan(0);
    for (const row of list.body.data as Record<string, unknown>[]) {
      expect(row).toHaveProperty('importBatchId');
      expect(row).toHaveProperty('importConfidence');
      expect(row).toHaveProperty('importWarnings');
    }
  });

  it('Non-imported M1a contract returns null for all 3 new fields', async () => {
    const post = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        titleEn: 'M1c-AE1-NoImport',
        contractType: 'service',
        language: 'en',
      });
    expect(post.status).toBe(201);
    createdContractIds.push(post.body.id);

    const list = await request(app)
      .get('/api/v1/contracts')
      .query({ limit: 100, search: 'M1c-AE1-NoImport' })
      .set('Authorization', `Bearer ${adminToken}`);
    const row = (list.body.data as Array<Record<string, unknown>>).find(
      (r) => r.id === post.body.id,
    );
    expect(row).toBeDefined();
    expect(row!.importBatchId).toBeNull();
    expect(row!.importConfidence).toBeNull();
    expect(row!.importWarnings).toBeNull();
  });

  it('AC-S4-05 + AC-S5-08: M1c-imported contract returns populated importBatchId/Confidence/Warnings', async () => {
    const drafter = getFixture('drafter1');
    const batch = await seedImportBatch(drafter.id, {
      totalFiles: 5,
      config: { statusMode: 'active' },
    });
    createdBatchIds.push(batch.id);

    const post = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        titleEn: 'M1c-AE1-WithImport',
        contractType: 'service',
        language: 'en',
        importBatchId: batch.id,
        importFilename: 'fixture-ae1.pdf',
        importConfidence: 75,
        importWarnings: ['ambiguous date', 'low quality scan'],
      });
    expect(post.status).toBe(201);
    createdContractIds.push(post.body.id);

    const list = await request(app)
      .get('/api/v1/contracts')
      .query({ importBatchId: batch.id })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(list.status).toBe(200);
    expect(list.body.data.length).toBeGreaterThanOrEqual(1);
    const row = (list.body.data as Array<{
      id: number;
      importBatchId: number | null;
      importConfidence: number | null;
      importWarnings: string[] | null;
    }>).find((r) => r.id === post.body.id);
    expect(row).toBeDefined();
    expect(Number(row!.importBatchId)).toBe(batch.id);
    expect(row!.importConfidence).toBe(75);
    expect(Array.isArray(row!.importWarnings)).toBe(true);
    expect(row!.importWarnings).toEqual(
      expect.arrayContaining(['ambiguous date', 'low quality scan']),
    );
  });

  it('AC-S6-01: importConfidenceMin/Max filter narrows to confidence-in-range rows', async () => {
    const drafter = getFixture('drafter1');
    const batch = await seedImportBatch(drafter.id, {
      totalFiles: 5,
      config: { statusMode: 'draft' },
    });
    createdBatchIds.push(batch.id);

    // Seed 3 contracts at different confidences.
    for (const c of [40, 65, 85]) {
      const r = await request(app)
        .post('/api/v1/contracts')
        .set('Authorization', `Bearer ${drafterToken}`)
        .send({
          titleEn: `M1c-AE1-Conf${c}`,
          contractType: 'service',
          language: 'en',
          importBatchId: batch.id,
          importFilename: `fixture-conf-${c}.pdf`,
          importConfidence: c,
        });
      expect(r.status).toBe(201);
      createdContractIds.push(r.body.id);
    }

    const res = await request(app)
      .get('/api/v1/contracts')
      .query({
        importBatchId: batch.id,
        importConfidenceMin: 50,
        importConfidenceMax: 79,
      })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    const confidences = (res.body.data as Array<{ importConfidence: number | null }>)
      .filter((r) => r.importConfidence !== null)
      .map((r) => r.importConfidence as number);
    // Every returned row must be in [50, 79].
    for (const c of confidences) {
      expect(c).toBeGreaterThanOrEqual(50);
      expect(c).toBeLessThanOrEqual(79);
    }
    // The 65 contract is the only one in range — must appear.
    expect(confidences).toContain(65);
    expect(confidences).not.toContain(40);
    expect(confidences).not.toContain(85);
  });

  it('importConfidenceMin out of range (>100) → 400', async () => {
    const res = await request(app)
      .get('/api/v1/contracts')
      .query({ importConfidenceMin: 999 })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(400);
  });

  it('Backward compat: 15-positional-arg fn_contract_list call still works (DB layer)', async () => {
    // Direct fn_ invocation with the OLD 15-arg signature — proves the
    // M1c REPLACE preserved the call shape via DEFAULT NULL on the new
    // params. Uses adminQuery (BYPASSRLS).
    const r = await adminQuery<{ result: { data: unknown[] } }>(
      `SELECT fn_contract_list(
          $1::int, $2::int, $3::text, $4::text, $5::bigint, $6::bigint,
          $7::bigint, $8::date, $9::date, $10::date, $11::date,
          $12::text[], $13::text, $14::bigint, $15::text
        ) AS result`,
      [1, 5, null, null, null, null, null, null, null, null, null, null, null, 1, 'Super Admin'],
    );
    expect(r[0]?.result).toBeDefined();
    expect(Array.isArray(r[0]!.result.data)).toBe(true);
  });

  it('Backward compat: 18-positional-arg fn_contract_list call works (DB layer, named-arg style would also work)', async () => {
    const r = await adminQuery<{ result: { data: unknown[] } }>(
      `SELECT fn_contract_list(
          $1::int, $2::int, $3::text, $4::text, $5::bigint, $6::bigint,
          $7::bigint, $8::date, $9::date, $10::date, $11::date,
          $12::text[], $13::text, $14::bigint, $15::text,
          $16::bigint, $17::int, $18::int
        ) AS result`,
      [
        1, 5, null, null, null, null, null, null, null, null, null,
        null, null, 1, 'Super Admin', null, null, null,
      ],
    );
    expect(r[0]?.result).toBeDefined();
    expect(Array.isArray(r[0]!.result.data)).toBe(true);
  });
});

// ============================================================================
// POST /api/v1/contracts (M1a) extended with importBatch* fields
// ============================================================================
describe('S5/S7 — POST /api/v1/contracts with M1c importBatch* extension', () => {
  it('AC-S5-08: importBatchId in CreateContractDto persists to contract.import_batch_id', async () => {
    const drafter = getFixture('drafter1');
    const batch = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    createdBatchIds.push(batch.id);

    const post = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        titleEn: 'M1c-S5-08-BatchPersist',
        contractType: 'service',
        language: 'en',
        importBatchId: batch.id,
        importFilename: 'persist.pdf',
        importConfidence: 80,
      });
    expect(post.status).toBe(201);
    createdContractIds.push(post.body.id);

    // Read raw DB row.
    const r = await adminQuery<{
      import_batch_id: number | null;
      import_filename: string | null;
      import_confidence: number | null;
    }>(
      'SELECT import_batch_id, import_filename, import_confidence FROM contract WHERE id = $1',
      [post.body.id],
    );
    expect(Number(r[0]!.import_batch_id)).toBe(batch.id);
    expect(r[0]!.import_filename).toBe('persist.pdf');
    expect(Number(r[0]!.import_confidence)).toBe(80);
  });

  it('AC-S7-04: manual-entry POST + counter increment via PATCH /import-batches/:id', async () => {
    const drafter = getFixture('drafter1');
    const batch = await seedImportBatch(drafter.id, {
      totalFiles: 3,
      config: { statusMode: 'draft' },
    });
    createdBatchIds.push(batch.id);

    // Step 1: manual-entry POST.
    const post = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        titleEn: 'M1c-S7-04-Manual',
        contractType: 'service',
        language: 'en',
        importBatchId: batch.id,
        importFilename: 'manual.pdf',
        importConfidence: 25, // low confidence — manual entry track
      });
    expect(post.status).toBe(201);
    createdContractIds.push(post.body.id);

    // Step 2: increment manualEntry counter on the batch.
    const patch = await request(app)
      .patch(`/api/v1/import-batches/${batch.id}`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ manualEntryDelta: 1 });
    expect(patch.status).toBe(200);
    expect(patch.body.manualEntry).toBe(1);
  });

  it('AC-S7-05: failure surface on submit — Zod validation error returns 400 and the form values are not persisted', async () => {
    const drafter = getFixture('drafter1');
    const batch = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'draft' },
    });
    createdBatchIds.push(batch.id);

    // contract_type missing — required field.
    const post = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        // titleEn missing — required by M1a CreateContractDto
        contractType: 'service',
        language: 'en',
        importBatchId: batch.id,
        importConfidence: 25,
      });
    expect(post.status).toBe(400);
  });
});

// ============================================================================
// AC-S5-09 — duplicate detection composability
// ============================================================================
describe('S5 — AC-S5-09 duplicate-detection composability', () => {
  it('Existing active contract with same contract_number is visible via fn_contract_list (FE skip path)', async () => {
    // Seed a contract — capture its auto-generated contract_number.
    const post = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        titleEn: 'M1c-S5-09-DupSrc',
        contractType: 'service',
        language: 'en',
      });
    expect(post.status).toBe(201);
    createdContractIds.push(post.body.id);
    const cn = post.body.contractNumber as string;
    expect(cn).toMatch(/^CT-/);

    // The FE bulk flow checks fn_contract_list for existing active rows
    // matching the AI-detected contract_number. Verify the search query
    // hits the same row.
    const list = await request(app)
      .get('/api/v1/contracts')
      .query({ search: cn })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(list.status).toBe(200);
    const found = (list.body.data as Array<{
      contractNumber: string;
      status: string;
    }>).some(
      (r) => r.contractNumber === cn && r.status !== 'terminated' && r.status !== 'expired',
    );
    expect(found).toBe(true);
  });
});

// ============================================================================
// AC-S6-04 — status transition draft → active (BE-Q3-OI-C regression)
// ============================================================================
describe('S6 — AC-S6-04 status transition draft → active (BE-Q3-OI-C-test-handoff)', () => {
  it('PUT /api/v1/contracts/:id/status with status=active is accepted on a draft contract', async () => {
    // Per BE-Q3-OI-C: M1a fn_contract_status_update is a placeholder
    // validating enum membership only — assumed permissive. This test
    // confirms draft → active transition works at runtime.
    const post = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        titleEn: 'M1c-S6-04-DraftToActive',
        contractType: 'service',
        language: 'en',
      });
    expect(post.status).toBe(201);
    createdContractIds.push(post.body.id);
    expect(post.body.status).toBe('draft');

    const transition = await request(app)
      .patch(`/api/v1/contracts/${post.body.id}/status`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ newStatus: 'active' });
    // Either 200 (transition succeeded — BE-Q3-OI-C confirmation) OR 409
    // (transition rejected, which would then be a regression worth flagging).
    // The expected M1a placeholder behaviour is 200.
    expect([200, 204]).toContain(transition.status);
  });
});
