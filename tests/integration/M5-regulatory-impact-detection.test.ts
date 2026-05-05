/**
 * M5 — Regulatory Impact Detection tests for S11..S13.
 *
 * Surfaces:
 *   - POST  /api/v1/regulatory-impacts/bulk-detect   (S11, fn_regulatory_impact_create_bulk DEFINER)
 *   - GET   /api/v1/regulatory-impacts               (S12, fn_regulatory_impact_list)
 *   - PATCH /api/v1/regulatory-impacts/:id/resolve   (S13, fn_regulatory_impact_resolve polymorphic)
 *
 * Special focus (highest-risk M5 paths):
 *   - S11 idempotency on (contract_id, regulation_id, regulatory_update_id)
 *     UNIQUE INDEX (Q7 COALESCE-sentinel)
 *   - S11 permission gate (regulations.manage required even though fn is DEFINER)
 *   - S11 contract_activity emit (whitelist 23→25 verification)
 *   - S12 AC-S12-02 'at least one filter' guard
 *   - S13 polymorphic permission OR-branch (drafter on own contract OR
 *     legal_counsel/platform_admin)
 *   - S13 AC-S13-02 pending un-resolves
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  cleanupContractsByIds,
  closeAdminPool,
  loginAdmin,
  type LoginResult,
  adminQuery,
} from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  signFixtureToken,
} from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';
import {
  cleanupRegulatoryArtifacts,
  countM5ContractActivity,
  getRegulatorIdByCode,
  readRegulatoryImpactById,
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
let executiveToken: string;

let mohreId: number;

const createdUpdateIds: number[] = [];
const createdRegulationIds: number[] = [];
const createdImpactIds: number[] = [];
const createdContractIds: number[] = [];
const SUITE_TAG = tagFor('reg-impact');

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
      regulatoryUpdateIds: createdUpdateIds,
      regulationIds: createdRegulationIds,
      contractIds: createdContractIds,
    });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M5-impact cleanup]', err);
  }
  try {
    if (createdContractIds.length > 0) {
      await cleanupContractsByIds(createdContractIds);
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M5-impact contract cleanup]', err);
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

const seedFixtureSet = async (label: string): Promise<{
  updateId: number;
  regulationId: number;
}> => {
  const updateId = await seedRegulatoryUpdate({
    regulatorId: mohreId,
    titleEn: `${SUITE_TAG} ${label}`,
    publishedDate: todayIso(-30),
    severity: 'medium',
    actorUserId: admin.user.id,
  });
  createdUpdateIds.push(updateId);
  const regulationId = await seedRegulation({
    referenceCode: `${SUITE_TAG}-${label}-${Math.floor(Math.random() * 1e9)}`.slice(0, 78),
    titleEn: `${SUITE_TAG} ${label} reg`,
    issuerId: mohreId,
    actorUserId: admin.user.id,
  });
  createdRegulationIds.push(regulationId);
  return { updateId, regulationId };
};

// ============================================================================
// S11 — POST /api/v1/regulatory-impacts/bulk-detect
// ============================================================================
describe('S11 — fn_regulatory_impact_create_bulk / POST /bulk-detect', () => {
  it('AC-S11-01: legal_counsel bulk-detects across 3 contracts — returns counts + ids', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S11-01');
    const c1 = await createDraftContract(adminToken);
    const c2 = await createDraftContract(adminToken);
    const c3 = await createDraftContract(adminToken);

    const res = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatoryUpdateId: updateId,
        regulationId,
        contractIds: [c1, c2, c3],
        impactPayload: {
          [String(c1)]: { impactScore: 80, noteEn: 'High impact', summaryEn: 'sumA' },
          [String(c2)]: { impactScore: 50, noteEn: 'Medium', summaryEn: 'sumB' },
          [String(c3)]: { impactScore: 20, noteEn: 'Low', summaryEn: 'sumC' },
        },
      });
    expect(res.status).toBe(201);
    expect(res.body.createdCount).toBe(3);
    expect(res.body.skippedDuplicateCount).toBe(0);
    expect(Array.isArray(res.body.impactIds)).toBe(true);
    expect(res.body.impactIds).toHaveLength(3);
    for (const iid of res.body.impactIds as number[]) {
      createdImpactIds.push(Number(iid));
    }

    // S2-19 byte-for-byte fn_contract_activity_create extension verification:
    // every impact insert must emit `regulatory_impact_detected`
    for (const cid of [c1, c2, c3]) {
      const count = await countM5ContractActivity(cid, 'regulatory_impact_detected');
      expect(count).toBe(1);
    }
  });

  it('AC-S11-02: idempotent re-runs — second call with same tuple returns skippedDuplicateCount=N', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S11-02');
    const c1 = await createDraftContract(adminToken);
    const c2 = await createDraftContract(adminToken);

    const payload = {
      regulatoryUpdateId: updateId,
      regulationId,
      contractIds: [c1, c2],
      impactPayload: {
        [String(c1)]: { impactScore: 60, noteEn: 'Run1' },
        [String(c2)]: { impactScore: 40, noteEn: 'Run1' },
      },
    };

    const r1 = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${legalToken}`)
      .send(payload);
    expect(r1.status).toBe(201);
    expect(r1.body.createdCount).toBe(2);
    expect(r1.body.skippedDuplicateCount).toBe(0);
    for (const iid of r1.body.impactIds as number[]) createdImpactIds.push(Number(iid));

    // Second call — exact same tuple — must skip both
    const r2 = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${legalToken}`)
      .send(payload);
    expect(r2.status).toBe(201);
    expect(r2.body.createdCount).toBe(0);
    expect(r2.body.skippedDuplicateCount).toBe(2);
    expect(r2.body.impactIds).toEqual([]);

    // Sanity — only one contract_activity per contract (no duplicate emit)
    const a1 = await countM5ContractActivity(c1, 'regulatory_impact_detected');
    expect(a1).toBe(1);
  });

  it('AC-S11-03: empty contractIds returns 400', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S11-03');
    const res = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatoryUpdateId: updateId,
        regulationId,
        contractIds: [],
        impactPayload: {},
      });
    expect(res.status).toBe(400);
  });

  it('AC-S11-04: regulatoryUpdateId not found returns 400', async () => {
    const { regulationId } = await seedFixtureSet('S11-04');
    const c1 = await createDraftContract(adminToken);
    const res = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatoryUpdateId: 999_999_999,
        regulationId,
        contractIds: [c1],
        impactPayload: {
          [String(c1)]: { impactScore: 50 },
        },
      });
    expect(res.status).toBe(400);
    const body = JSON.stringify(res.body).toLowerCase();
    expect(body).toContain('regulatoryupdateid');
  });

  it('AC-S11-05: regulationId not found returns 400', async () => {
    const { updateId } = await seedFixtureSet('S11-05');
    const c1 = await createDraftContract(adminToken);
    const res = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatoryUpdateId: updateId,
        regulationId: 999_999_999,
        contractIds: [c1],
        impactPayload: {
          [String(c1)]: { impactScore: 50 },
        },
      });
    expect(res.status).toBe(400);
    const body = JSON.stringify(res.body).toLowerCase();
    expect(body).toContain('regulationid');
  });

  it('AC-S11-06: contract_drafter (no regulations.manage) receives 403', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S11-06');
    const c1 = await createDraftContract(adminToken);
    const res = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        regulatoryUpdateId: updateId,
        regulationId,
        contractIds: [c1],
        impactPayload: {
          [String(c1)]: { impactScore: 50 },
        },
      });
    expect(res.status).toBe(403);
  });

  it('AC-S11-08 (TOCTOU/permission narrowing): legal_counsel writing on contracts they don\'t own succeeds via DEFINER', async () => {
    // Drafter creates a contract; legal_counsel writes impact on it. The
    // DEFINER carve-out + permission gate at fn body line 1 must allow this.
    const { updateId, regulationId } = await seedFixtureSet('S11-08');
    const drafterContract = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        titleEn: `${SUITE_TAG}-S11-08`,
        contractType: 'employment',
        language: 'en',
      });
    expect(drafterContract.status).toBe(201);
    const cid = Number(drafterContract.body.id);
    createdContractIds.push(cid);

    const res = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatoryUpdateId: updateId,
        regulationId,
        contractIds: [cid],
        impactPayload: {
          [String(cid)]: { impactScore: 70, noteEn: 'Legal counsel writes on drafter\'s contract' },
        },
      });
    expect(res.status).toBe(201);
    expect(res.body.createdCount).toBe(1);
    for (const iid of res.body.impactIds as number[]) createdImpactIds.push(Number(iid));
  });

  it('camelCase keys honoured byte-for-byte (impactScore, noteEn, noteAr, summaryEn, summaryAr land in the right columns)', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S11-keys');
    const c1 = await createDraftContract(adminToken);

    const res = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatoryUpdateId: updateId,
        regulationId,
        contractIds: [c1],
        impactPayload: {
          [String(c1)]: {
            impactScore: 42,
            noteEn: 'Note EN',
            noteAr: 'ملاحظة عربية',
            summaryEn: 'Summary EN',
            summaryAr: 'ملخص عربي',
          },
        },
      });
    expect(res.status).toBe(201);
    const impactId = Number(res.body.impactIds[0]);
    createdImpactIds.push(impactId);
    const row = await readRegulatoryImpactById(impactId);
    expect(row).not.toBeNull();
    expect(row!['impact_score']).toBe(42);
    expect(row!['impact_note_en']).toBe('Note EN');
    expect(row!['impact_note_ar']).toBe('ملاحظة عربية');
    expect(row!['impact_summary_en']).toBe('Summary EN');
    expect(row!['impact_summary_ar']).toBe('ملخص عربي');
  });
});

// ============================================================================
// S12 — GET /api/v1/regulatory-impacts
// ============================================================================
describe('S12 — fn_regulatory_impact_list / GET /api/v1/regulatory-impacts', () => {
  it('AC-S12-02: returns 400 with field=filters when no scoping filter provided', async () => {
    const res = await request(app)
      .get('/api/v1/regulatory-impacts')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(400);
    const body = JSON.stringify(res.body).toLowerCase();
    expect(body).toContain('filters');
  });

  it('AC-S12-01: returns paginated list when scoping filter is provided', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S12-01');
    const c1 = await createDraftContract(adminToken);
    const i1 = await seedRegulatoryImpact({
      contractId: c1,
      regulationId,
      regulatoryUpdateId: updateId,
      impactScore: 30,
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(i1);

    const res = await request(app)
      .get('/api/v1/regulatory-impacts')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ regulatoryUpdateId: updateId });
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.pagination).toBeDefined();
    const ids = (res.body.data as Array<{ id: number }>).map((r) => Number(r.id));
    expect(ids).toContain(i1);
  });

  it('AC-S12-03: filtering by resolved=true excludes unresolved rows', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S12-03');
    const c1 = await createDraftContract(adminToken);
    const i_unresolved = await seedRegulatoryImpact({
      contractId: c1,
      regulationId,
      regulatoryUpdateId: updateId,
      resolved: false,
      actorUserId: admin.user.id,
    });
    const i_resolved = await seedRegulatoryImpact({
      contractId: c1,
      regulationId,
      regulatoryUpdateId: null, // structural to avoid conflict on the COALESCE-sentinel UNIQUE
      resolved: true,
      resolutionAction: 'amended',
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(i_unresolved, i_resolved);

    const res = await request(app)
      .get('/api/v1/regulatory-impacts')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ regulationId, resolved: 'true' });
    expect(res.status).toBe(200);
    for (const row of res.body.data as Array<{ resolved?: boolean }>) {
      expect(row.resolved).toBe(true);
    }
  });
});

// ============================================================================
// S13 — PATCH /api/v1/regulatory-impacts/:id/resolve  (polymorphic permission)
// ============================================================================
describe('S13 — fn_regulatory_impact_resolve / PATCH /:id/resolve', () => {
  it('AC-S13-01: legal_counsel resolves with action=amended', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S13-01');
    const c1 = await createDraftContract(adminToken);
    const impactId = await seedRegulatoryImpact({
      contractId: c1,
      regulationId,
      regulatoryUpdateId: updateId,
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(impactId);

    const res = await request(app)
      .patch(`/api/v1/regulatory-impacts/${impactId}/resolve`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ resolutionAction: 'amended', resolutionNote: 'Patched the clause' });
    expect(res.status).toBe(200);
    expect(res.body.id).toBeDefined();
    expect(res.body.resolved).toBe(true);
    expect(res.body.resolutionAction).toBe('amended');

    const row = await readRegulatoryImpactById(impactId);
    expect(row!['resolved']).toBe(true);
    expect(row!['resolution_action']).toBe('amended');
    expect(row!['resolution_note']).toBe('Patched the clause');

    // AC-S13 — emits regulatory_impact_resolved on contract_activity
    const count = await countM5ContractActivity(c1, 'regulatory_impact_resolved');
    expect(count).toBeGreaterThanOrEqual(1);
  });

  it('AC-S13-02: pending un-resolves (sets resolved=FALSE)', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S13-02');
    const c1 = await createDraftContract(adminToken);
    const impactId = await seedRegulatoryImpact({
      contractId: c1,
      regulationId,
      regulatoryUpdateId: updateId,
      resolved: true,
      resolutionAction: 'amended',
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(impactId);

    const res = await request(app)
      .patch(`/api/v1/regulatory-impacts/${impactId}/resolve`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ resolutionAction: 'pending' });
    expect(res.status).toBe(200);
    expect(res.body.resolved).toBe(false);
    expect(res.body.resolutionAction).toBe('pending');
  });

  it('AC-S13-03: invalid resolutionAction returns 400', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S13-03');
    const c1 = await createDraftContract(adminToken);
    const impactId = await seedRegulatoryImpact({
      contractId: c1,
      regulationId,
      regulatoryUpdateId: updateId,
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(impactId);
    const res = await request(app)
      .patch(`/api/v1/regulatory-impacts/${impactId}/resolve`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ resolutionAction: 'not-a-real-action' });
    expect(res.status).toBe(400);
  });

  it('AC-S13-04: returns 404 when impact id not found', async () => {
    const res = await request(app)
      .patch('/api/v1/regulatory-impacts/999999999/resolve')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({ resolutionAction: 'amended' });
    expect(res.status).toBe(404);
  });

  it('AC-S13-05 (polymorphic): drafter on OWN contract can resolve', async () => {
    // Setup: drafter1 creates the contract; impact attached.
    const drafter = getFixture('drafter1');
    const { updateId, regulationId } = await seedFixtureSet('S13-05');
    const cRes = await request(app)
      .post('/api/v1/contracts')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        titleEn: `${SUITE_TAG}-S13-05`,
        contractType: 'employment',
        language: 'en',
      });
    expect(cRes.status).toBe(201);
    const cid = Number(cRes.body.id);
    createdContractIds.push(cid);

    // Confirm contract.drafted_by indeed equals drafter1.id
    const probe = await adminQuery<{ drafted_by: number | string }>(
      'SELECT drafted_by FROM contract WHERE id = $1',
      [cid],
    );
    expect(Number(probe[0]!.drafted_by)).toBe(drafter.id);

    // Seed an impact via direct admin path (not affected by drafter perms)
    const impactId = await seedRegulatoryImpact({
      contractId: cid,
      regulationId,
      regulatoryUpdateId: updateId,
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(impactId);

    // Drafter resolves their own contract's impact — should succeed (200)
    // because polymorphic OR-branch matches contract.drafted_by = current_user.
    const res = await request(app)
      .patch(`/api/v1/regulatory-impacts/${impactId}/resolve`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ resolutionAction: 'waived', resolutionNote: 'Drafter clears own clause' });
    expect(res.status).toBe(200);
    expect(res.body.resolved).toBe(true);
  });

  it('AC-S13-05 (polymorphic): drafter on OTHER contract receives 403 from fn body', async () => {
    // The contract is admin-owned (drafted_by = admin), drafter is not admin.
    const { updateId, regulationId } = await seedFixtureSet('S13-05b');
    const c1 = await createDraftContract(adminToken); // admin-drafted
    const impactId = await seedRegulatoryImpact({
      contractId: c1,
      regulationId,
      regulatoryUpdateId: updateId,
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(impactId);

    const res = await request(app)
      .patch(`/api/v1/regulatory-impacts/${impactId}/resolve`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ resolutionAction: 'amended' });
    expect(res.status).toBe(403);
  });

  it('AC-S13-05 (polymorphic): contract_recipient (no regulations.read) receives 403 at route gate', async () => {
    const { updateId, regulationId } = await seedFixtureSet('S13-05c');
    const c1 = await createDraftContract(adminToken);
    const impactId = await seedRegulatoryImpact({
      contractId: c1,
      regulationId,
      regulatoryUpdateId: updateId,
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(impactId);
    const res = await request(app)
      .patch(`/api/v1/regulatory-impacts/${impactId}/resolve`)
      .set('Authorization', `Bearer ${recipientToken}`)
      .send({ resolutionAction: 'amended' });
    expect(res.status).toBe(403);
  });
});

// ============================================================================
// Cross-module sanity — fn_contract_activity_create whitelist 25 values
// ============================================================================
describe('Cross-module — contract_activity whitelist 25 (M4 23 + M5 2)', () => {
  it('post-migration 047: emits regulatory_impact_detected via fn_contract_activity_create', async () => {
    const { updateId, regulationId } = await seedFixtureSet('xmod-detect');
    const c1 = await createDraftContract(adminToken);
    const res = await request(app)
      .post('/api/v1/regulatory-impacts/bulk-detect')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        regulatoryUpdateId: updateId,
        regulationId,
        contractIds: [c1],
        impactPayload: {
          [String(c1)]: { impactScore: 99 },
        },
      });
    expect(res.status).toBe(201);
    for (const iid of res.body.impactIds as number[]) createdImpactIds.push(Number(iid));
    const count = await countM5ContractActivity(c1, 'regulatory_impact_detected');
    expect(count).toBe(1);
  });

  it('post-migration 047: emits regulatory_impact_resolved via fn_contract_activity_create', async () => {
    const { updateId, regulationId } = await seedFixtureSet('xmod-resolve');
    const c1 = await createDraftContract(adminToken);
    const impactId = await seedRegulatoryImpact({
      contractId: c1,
      regulationId,
      regulatoryUpdateId: updateId,
      actorUserId: admin.user.id,
    });
    createdImpactIds.push(impactId);

    const res = await request(app)
      .patch(`/api/v1/regulatory-impacts/${impactId}/resolve`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ resolutionAction: 'out_of_scope' });
    expect(res.status).toBe(200);
    const count = await countM5ContractActivity(c1, 'regulatory_impact_resolved');
    expect(count).toBe(1);
  });
});
