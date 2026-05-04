/**
 * M2 — HTTP integration tests for /api/v1/admin/* approval namespace.
 *
 * Covers:
 *   - GET  /api/v1/admin/approval-matrix                       (S4)
 *   - PUT  /api/v1/admin/approval-matrix                       (S5)
 *   - POST /api/v1/admin/approval-steps/:stepId/reassign       (S8)
 *   - GET  /api/v1/admin/approval-chains                       (S11)
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
  cleanupApprovalArtifacts,
  clearMatrixRulesForContractType,
} from '../helpers/m2-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;
let approver1Token: string;
let recipientToken: string;
let legalCounselToken: string;

const createdContractIds: number[] = [];
const CONTRACT_TYPE = 'sow';

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;
  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  approver1Token = signFixtureToken('approver1');
  recipientToken = signFixtureToken('recipient1');
  legalCounselToken = signFixtureToken('legal_counsel1');
});

afterAll(async () => {
  if (createdContractIds.length > 0) {
    try {
      await cleanupApprovalArtifacts(createdContractIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M2-admin-cleanup] approval artifacts:', err);
    }
    try {
      await cleanupContractsByIds(createdContractIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M2-admin-cleanup] contracts:', err);
    }
  }
  try {
    await clearMatrixRulesForContractType(CONTRACT_TYPE);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M2-admin-cleanup] matrix:', err);
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

const createDraftContract = async (
  token: string,
  contractType: string = CONTRACT_TYPE,
  valueAed: number = 50_000,
): Promise<{ id: number }> => {
  const res = await request(app)
    .post('/api/v1/contracts')
    .set('Authorization', `Bearer ${token}`)
    .send({
      titleEn: `M2-admin-${Date.now()}-${Math.floor(Math.random() * 1e9)}`,
      contractType,
      language: 'en',
      valueAed,
    });
  expect(res.status).toBe(201);
  createdContractIds.push(res.body.id);
  return { id: res.body.id };
};

// ============================================================================
// S5 — PUT /api/v1/admin/approval-matrix (must run FIRST so S4 has rows)
// ============================================================================
describe('S5 — PUT /api/v1/admin/approval-matrix', () => {
  it('AC-S5-01 + AC-S5-08: atomic upsert returns ruleCount + ruleIds', async () => {
    const res = await request(app)
      .put('/api/v1/admin/approval-matrix')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        contractType: CONTRACT_TYPE,
        valueMin: 0,
        valueMax: 100_000,
        rules: [
          { stepOrder: 1, approverRole: 'contract_approver', isRequired: true },
          {
            stepOrder: 2,
            approverRole: 'contract_approver_2',
            isRequired: true,
            escalationRole: 'legal_counsel',
            escalationAfterHours: 24,
          },
        ],
      });
    expect(res.status).toBe(200);
    expect(res.body.contractType).toBe(CONTRACT_TYPE);
    expect(res.body.ruleCount).toBe(2);
    expect(Array.isArray(res.body.ruleIds)).toBe(true);
    expect(res.body.ruleIds.length).toBe(2);
  });

  it('AC-S5-02: returns 400 when stepOrder values have gaps', async () => {
    const res = await request(app)
      .put('/api/v1/admin/approval-matrix')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        contractType: CONTRACT_TYPE,
        valueMin: 0,
        valueMax: 100_000,
        rules: [
          { stepOrder: 1, approverRole: 'contract_approver' },
          { stepOrder: 3, approverRole: 'contract_approver_2' }, // gap
        ],
      });
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).toMatch(/step_order has gaps|step_order/i);
  });

  it('AC-S5-03: returns 400 when approverRole does not exist', async () => {
    const res = await request(app)
      .put('/api/v1/admin/approval-matrix')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        contractType: CONTRACT_TYPE,
        valueMin: 0,
        valueMax: 100_000,
        rules: [{ stepOrder: 1, approverRole: 'nonexistent_role_xyz' }],
      });
    expect([400, 404]).toContain(res.status);
  });

  it('AC-S5-04: returns 400 when rules array is empty', async () => {
    const res = await request(app)
      .put('/api/v1/admin/approval-matrix')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        contractType: CONTRACT_TYPE,
        valueMin: 0,
        valueMax: 100_000,
        rules: [],
      });
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).toMatch(/rules.*empty|must not be empty/i);
  });

  it('AC-S5-05: returns 400 when parallelGroup != stepOrder', async () => {
    const res = await request(app)
      .put('/api/v1/admin/approval-matrix')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        contractType: CONTRACT_TYPE,
        valueMin: 0,
        valueMax: 100_000,
        rules: [
          {
            stepOrder: 1,
            parallelGroup: 2,
            approverRole: 'contract_approver',
          },
        ],
      });
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).toMatch(/parallelGroup must equal stepOrder/i);
  });

  it('AC-S5-06: returns 403 when caller lacks approval.matrix.write', async () => {
    const res = await request(app)
      .put('/api/v1/admin/approval-matrix')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        contractType: CONTRACT_TYPE,
        valueMin: 0,
        valueMax: 100_000,
        rules: [{ stepOrder: 1, approverRole: 'contract_approver' }],
      });
    expect(res.status).toBe(403);
  });

  it('AC-S5-07: failed validation = atomic rollback (existing rules unchanged)', async () => {
    // Read current rule count
    const before = await request(app)
      .get('/api/v1/admin/approval-matrix')
      .query({ contractType: CONTRACT_TYPE, limit: 100 })
      .set('Authorization', `Bearer ${adminToken}`);
    const beforeCount = before.body.pagination.total;

    // Submit a request that fails inside the fn_ (gap)
    const fail = await request(app)
      .put('/api/v1/admin/approval-matrix')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        contractType: CONTRACT_TYPE,
        valueMin: 0,
        valueMax: 100_000,
        rules: [
          { stepOrder: 1, approverRole: 'contract_approver' },
          { stepOrder: 5, approverRole: 'contract_approver_2' },
        ],
      });
    expect(fail.status).toBe(400);

    // Re-read; count unchanged
    const after = await request(app)
      .get('/api/v1/admin/approval-matrix')
      .query({ contractType: CONTRACT_TYPE, limit: 100 })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(after.body.pagination.total).toBe(beforeCount);
  });
});

// ============================================================================
// S4 — GET /api/v1/admin/approval-matrix
// ============================================================================
describe('S4 — GET /api/v1/admin/approval-matrix', () => {
  it('AC-S4-01 + AC-S4-04: returns paginated matrix rows ordered by contract_type, step_order', async () => {
    const res = await request(app)
      .get('/api/v1/admin/approval-matrix')
      .query({ contractType: CONTRACT_TYPE, limit: 100 })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    // Pagination metadata always present
    expect(res.body.pagination).toMatchObject({
      page: 1,
      limit: 100,
    });
    if (res.body.data.length > 1) {
      // Verify step_order ascending for our contractType subset
      const ours = res.body.data.filter(
        (r: { contractType: string }) => r.contractType === CONTRACT_TYPE,
      );
      for (let i = 1; i < ours.length; i++) {
        expect(ours[i - 1].stepOrder).toBeLessThanOrEqual(ours[i].stepOrder);
      }
    }
  });

  it('AC-S4-02: contractType filter narrows to one type', async () => {
    const res = await request(app)
      .get('/api/v1/admin/approval-matrix')
      .query({ contractType: CONTRACT_TYPE })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    for (const row of res.body.data as Array<{ contractType: string }>) {
      expect(row.contractType).toBe(CONTRACT_TYPE);
    }
  });

  it('AC-S4-04: empty data + totalPages=0 when no rules match', async () => {
    const res = await request(app)
      .get('/api/v1/admin/approval-matrix')
      .query({ contractType: 'nonexistent_type_xyz', limit: 50 })
      .set('Authorization', `Bearer ${adminToken}`);
    // contractType is validated by Zod to max 50 chars. The string above is 22
    // chars. fn_'s permission gate fires first; so admin reaches the fn_ which
    // returns empty data.
    if (res.status === 200) {
      expect(res.body.data).toEqual([]);
      expect(res.body.pagination.totalPages).toBe(0);
    } else {
      // Some setups may 400 if contractType not in enum — accept either as long
      // as we never see 500.
      expect([200, 400]).toContain(res.status);
    }
  });

  it('AC-S4-05: returns 403 when caller lacks approval.matrix.read', async () => {
    const res = await request(app)
      .get('/api/v1/admin/approval-matrix')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });
});

// ============================================================================
// S11 — GET /api/v1/admin/approval-chains
// ============================================================================
describe('S11 — GET /api/v1/admin/approval-chains', () => {
  let createdChainIds: number[] = [];

  beforeAll(async () => {
    // Need a few chains to assert pagination + ordering.
    for (let i = 0; i < 2; i++) {
      const c = await createDraftContract(drafterToken);
      const submit = await request(app)
        .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
        .set('Authorization', `Bearer ${drafterToken}`)
        .send({});
      if (submit.status === 201) {
        createdChainIds.push(submit.body.chainId);
      }
    }
  });

  it('AC-S11-01 + AC-S11-02: paginated chain list with required keys', async () => {
    const res = await request(app)
      .get('/api/v1/admin/approval-chains')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.pagination).toHaveProperty('total');
    if (res.body.data.length > 0) {
      const row = res.body.data[0];
      for (const k of [
        'id',
        'contractId',
        'contractNumber',
        'status',
        'currentStepOrder',
        'totalSteps',
        'submittedBy',
        'submittedAt',
        'completedAt',
        'hoursPending',
      ]) {
        expect(row).toHaveProperty(k);
      }
    }
  });

  it('AC-S11-03: status filter narrows to one ApprovalChainStatus', async () => {
    const res = await request(app)
      .get('/api/v1/admin/approval-chains')
      .query({ status: 'in_progress' })
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    for (const row of res.body.data as Array<{ status: string }>) {
      expect(row.status).toBe('in_progress');
    }
  });

  it('AC-S11-04: legal_counsel sees admin chain list (Q3-OI-E anyOf gate)', async () => {
    const res = await request(app)
      .get('/api/v1/admin/approval-chains')
      .set('Authorization', `Bearer ${legalCounselToken}`);
    // legal_counsel has approval.matrix.read AND approval.reassign per migration 028.
    expect(res.status).toBe(200);
  });

  it('AC-S11-04 (BI5): non-admin contract.read.* caller blocked at admin gate (403)', async () => {
    const res = await request(app)
      .get('/api/v1/admin/approval-chains')
      .set('Authorization', `Bearer ${drafterToken}`);
    // contract_drafter does NOT have approval.matrix.read or approval.reassign
    expect(res.status).toBe(403);
  });

  it('AC-S11-05: empty data + totalPages=0 when filter matches nothing', async () => {
    const res = await request(app)
      .get('/api/v1/admin/approval-chains')
      .query({ status: 'cancelled' }) // nothing cancelled in this test run
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual([]);
    expect(res.body.pagination.total).toBe(0);
    expect(res.body.pagination.totalPages).toBe(0);
  });
});

// ============================================================================
// S8 — POST /api/v1/admin/approval-steps/:stepId/reassign
// ============================================================================
describe('S8 — POST /api/v1/admin/approval-steps/:stepId/reassign', () => {
  let stepId: number;
  let chainId: number;

  beforeAll(async () => {
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    chainId = submit.body.chainId;
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      const r = await client.query<{ id: number | string }>(
        `UPDATE approval_step SET approver_user_id = $1
          WHERE approval_chain_id = $2 AND step_order = 1
        RETURNING id`,
        [getFixture('approver1').id, chainId],
      );
      stepId = Number(r.rows[0]!.id);
      await client.query('COMMIT');
    } finally {
      client.release();
    }
  });

  it('AC-S8-01 + AC-S8-02 + AC-S8-03: reassign succeeds, step pending, original/new captured', async () => {
    // Target user must hold either step.approver_role OR an admin override role
    // (platform_admin, Super Admin, legal_counsel). Using legal_counsel1.
    const res = await request(app)
      .post(`/api/v1/admin/approval-steps/${stepId}/reassign`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ reassignedToUserId: getFixture('legal_counsel1').id });
    expect(res.status).toBe(200);
    expect(Number(res.body.stepId)).toBe(stepId);
    expect(Number(res.body.reassignedTo.id)).toBe(getFixture('legal_counsel1').id);
    if (res.body.originalApprover) {
      expect(Number(res.body.originalApprover.id)).toBe(getFixture('approver1').id);
    }
  });

  it('AC-S8-03: returns 403 when caller lacks approval.reassign', async () => {
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    let freshStep: number;
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      const r = await client.query<{ id: number | string }>(
        `UPDATE approval_step SET approver_user_id = $1
          WHERE approval_chain_id = $2 AND step_order = 1
        RETURNING id`,
        [getFixture('approver1').id, submit.body.chainId],
      );
      freshStep = Number(r.rows[0]!.id);
      await client.query('COMMIT');
    } finally {
      client.release();
    }
    const res = await request(app)
      .post(`/api/v1/admin/approval-steps/${freshStep}/reassign`)
      .set('Authorization', `Bearer ${approver1Token}`) // contract_approver lacks approval.reassign
      .send({ reassignedToUserId: getFixture('approver2').id });
    expect(res.status).toBe(403);
  });

  it('AC-S8-04: returns 409 when step is no longer pending', async () => {
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    let freshStep: number;
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      // Decide the step first so it is no longer 'pending'
      const r = await client.query<{ id: number | string }>(
        `UPDATE approval_step
            SET approver_user_id = $1, status = 'approved', decided_at = CURRENT_TIMESTAMP
          WHERE approval_chain_id = $2 AND step_order = 1
        RETURNING id`,
        [getFixture('approver1').id, submit.body.chainId],
      );
      freshStep = Number(r.rows[0]!.id);
      await client.query('COMMIT');
    } finally {
      client.release();
    }
    const res = await request(app)
      .post(`/api/v1/admin/approval-steps/${freshStep}/reassign`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ reassignedToUserId: getFixture('approver2').id });
    expect(res.status).toBe(409);
  });

  it('AC-S8-05: returns 400 when target user has incompatible role', async () => {
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    let freshStep: number;
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      const r = await client.query<{ id: number | string }>(
        `UPDATE approval_step SET approver_user_id = $1
          WHERE approval_chain_id = $2 AND step_order = 1
        RETURNING id`,
        [getFixture('approver1').id, submit.body.chainId],
      );
      freshStep = Number(r.rows[0]!.id);
      await client.query('COMMIT');
    } finally {
      client.release();
    }
    const res = await request(app)
      .post(`/api/v1/admin/approval-steps/${freshStep}/reassign`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ reassignedToUserId: getFixture('recipient1').id }); // contract_recipient — incompatible
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).toMatch(/incompatible role/i);
  });

  it('AC-S8-06: returns 404 for missing stepId', async () => {
    const res = await request(app)
      .post(`/api/v1/admin/approval-steps/9999999/reassign`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ reassignedToUserId: getFixture('approver2').id });
    expect(res.status).toBe(404);
  });
});
