/**
 * M2 — HTTP integration tests for /api/v1/approvals/* and
 * /api/v1/contracts/:id/{approval-chain*,submit-for-approval} endpoints.
 *
 * Covers:
 *   - GET  /api/v1/approvals/my-pending                       (S1)
 *   - POST /api/v1/approvals/:stepId/decide                   (S2)
 *   - POST /api/v1/approvals/:stepId/delegate                 (S3)
 *   - POST /api/v1/contracts/:id/approval-chain/preview       (S6)
 *   - POST /api/v1/contracts/:id/submit-for-approval          (S7)
 *   - GET  /api/v1/contracts/:id/approval-chain               (S10)
 *
 * Strategy: stand up the live Express app, log in as the admin to obtain a
 * Super Admin token, mint fixture-user tokens via signFixtureToken (drafter1,
 * approver1, approver2, recipient1, legal_counsel1) for role-specific paths.
 * Seed approval_matrix rules directly via the BYPASSRLS pool so the chain has
 * deterministic shape across tests.
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
  seedMatrixRules,
} from '../helpers/m2-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;
let approver1Token: string;
let approver2Token: string;
let recipientToken: string;

const createdContractIds: number[] = [];
const CONTRACT_TYPE = 'employment'; // a value not in the M1c-cross-module test (avoids matrix collision)

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;
  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  approver1Token = signFixtureToken('approver1');
  approver2Token = signFixtureToken('approver2');
  recipientToken = signFixtureToken('recipient1');

  // Seed matrix rules used by S6/S7/S10
  await seedMatrixRules(
    CONTRACT_TYPE,
    0,
    100_000,
    [
      { stepOrder: 1, approverRole: 'contract_approver', isRequired: true },
      { stepOrder: 2, approverRole: 'contract_approver_2', isRequired: true },
    ],
    getFixture('drafter1').id,
  );
});

afterAll(async () => {
  if (createdContractIds.length > 0) {
    try {
      await cleanupApprovalArtifacts(createdContractIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M2-approvals-cleanup] approval artifacts:', err);
    }
    try {
      await cleanupContractsByIds(createdContractIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M2-approvals-cleanup] contracts:', err);
    }
  }
  try {
    await clearMatrixRulesForContractType(CONTRACT_TYPE);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M2-approvals-cleanup] matrix:', err);
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

const createDraftContract = async (
  token: string,
  valueAed: number = 50_000,
  contractType: string = CONTRACT_TYPE,
): Promise<{ id: number; contractNumber: string; titleEn: string; status: string }> => {
  const res = await request(app)
    .post('/api/v1/contracts')
    .set('Authorization', `Bearer ${token}`)
    .send({
      titleEn: `M2-int-${Date.now()}-${Math.floor(Math.random() * 1e9)}`,
      contractType,
      language: 'en',
      valueAed,
    });
  expect(res.status).toBe(201);
  createdContractIds.push(res.body.id);
  return res.body as { id: number; contractNumber: string; titleEn: string; status: string };
};

// ============================================================================
// S6 — POST /contracts/:id/approval-chain/preview
// ============================================================================
describe('S6 — POST /api/v1/contracts/:id/approval-chain/preview', () => {
  it('AC-S6-01: returns ordered steps and hasNoMatchingRule=false on configured matrix', async () => {
    const c = await createDraftContract(drafterToken);
    const res = await request(app)
      .post(`/api/v1/contracts/${c.id}/approval-chain/preview`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ contractType: CONTRACT_TYPE, valueAed: 50_000 });
    expect(res.status).toBe(200);
    expect(res.body.contractType).toBe(CONTRACT_TYPE);
    expect(res.body.hasNoMatchingRule).toBe(false);
    expect(Array.isArray(res.body.steps)).toBe(true);
    expect(res.body.steps.length).toBe(2);
  });

  it('AC-S6-03: hasNoMatchingRule=true when no rule applies', async () => {
    const c = await createDraftContract(drafterToken);
    const res = await request(app)
      .post(`/api/v1/contracts/${c.id}/approval-chain/preview`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ contractType: 'nda', valueAed: 999_999_999 });
    expect(res.status).toBe(200);
    expect(res.body.hasNoMatchingRule).toBe(true);
    expect(res.body.steps).toEqual([]);
  });

  it('AC-S6-04: returns 400 with field=valueAed when valueAed < 0', async () => {
    const c = await createDraftContract(drafterToken);
    const res = await request(app)
      .post(`/api/v1/contracts/${c.id}/approval-chain/preview`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ contractType: CONTRACT_TYPE, valueAed: -1 });
    expect(res.status).toBe(400);
    // The route uses the validation middleware which surfaces a Zod error envelope.
    // Match the field reference loosely.
    const body = JSON.stringify(res.body);
    expect(body).toMatch(/valueAed/i);
  });

  it('Returns 401 when no JWT supplied', async () => {
    const c = await createDraftContract(drafterToken);
    const res = await request(app)
      .post(`/api/v1/contracts/${c.id}/approval-chain/preview`)
      .send({ contractType: CONTRACT_TYPE, valueAed: 50_000 });
    expect(res.status).toBe(401);
  });
});

// ============================================================================
// S7 — POST /contracts/:id/submit-for-approval
// ============================================================================
describe('S7 — POST /api/v1/contracts/:id/submit-for-approval', () => {
  it('AC-S7-01: returns 201 with chain payload', async () => {
    const c = await createDraftContract(drafterToken);
    const res = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    expect(res.status).toBe(201);
    expect(res.body.contractId).toBe(c.id);
    expect(res.body.totalSteps).toBe(2);
    expect(res.body.currentStepOrder).toBe(1);
    expect(res.body.newContractStatus).toBe('in_approval');
  });

  it('AC-S7-04: returns 409 when an in-progress chain already exists', async () => {
    const c = await createDraftContract(drafterToken);
    const first = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    expect(first.status).toBe(201);
    const second = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    expect(second.status).toBe(409);
    const body = JSON.stringify(second.body);
    // Either the explicit duplicate-chain raise or the contract.status pre-check
    // raise is acceptable — both signal "no second chain". The fn_'s status-
    // precheck happens before the chain-existence pre-check when the contract
    // was already transitioned to in_approval by the first call.
    expect(body).toMatch(/already has an in-progress|Invalid transition from in_approval/i);
  });

  it('AC-S7-05: returns 403 when caller lacks approval.submit_for_review', async () => {
    const c = await createDraftContract(drafterToken);
    const res = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${recipientToken}`)
      .send({});
    expect(res.status).toBe(403);
  });

  it('AC-S7-06: returns 404 when contract does not exist', async () => {
    const res = await request(app)
      .post(`/api/v1/contracts/9999999/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    // Contract not found OR not visible. Either way, drafter does not see it.
    expect([403, 404]).toContain(res.status);
  });

  it('AC-S7-03: returns 400 when no matrix rule applies', async () => {
    // Create with a contract_type that has no configured rules at this value.
    // 'nda' has no matrix rules in this run.
    const c = await createDraftContract(drafterToken, 99_999, 'nda');
    const res = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    expect(res.status).toBe(400);
    const body = JSON.stringify(res.body);
    expect(body).toMatch(/No approval rule configured/i);
  });
});

// ============================================================================
// S2 — POST /approvals/:stepId/decide
// ============================================================================
describe('S2 — POST /api/v1/approvals/:stepId/decide', () => {
  it('AC-S2-01: approve happy path returns 200 with decision payload', async () => {
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    expect(submit.status).toBe(201);
    const chainId = submit.body.chainId;

    // Force approver1 onto step 1 via direct DB write so AC-S2-04 doesn't fire.
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    let stepId: number;
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

    const decide = await request(app)
      .post(`/api/v1/approvals/${stepId}/decide`)
      .set('Authorization', `Bearer ${approver1Token}`)
      .send({ decision: 'approve' });
    expect(decide.status).toBe(200);
    expect(decide.body.newStepStatus).toBe('approved');
    expect(decide.body.newChainStatus).toBe('in_progress'); // step 2 still pending
    expect(decide.body.advancedToStepOrder).toBe(2);
  });

  it('AC-S2-02: reject without decisionNote returns 400', async () => {
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    const chainId = submit.body.chainId;
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    let stepId: number;
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
    const res = await request(app)
      .post(`/api/v1/approvals/${stepId}/decide`)
      .set('Authorization', `Bearer ${approver1Token}`)
      .send({ decision: 'reject' });
    expect(res.status).toBe(400);
    const body = JSON.stringify(res.body);
    expect(body).toMatch(/decisionNote/i);
  });

  it('AC-S2-03: request_resubmission with decisionNote → 200, contract back to draft', async () => {
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    const chainId = submit.body.chainId;
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    let stepId: number;
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
    const res = await request(app)
      .post(`/api/v1/approvals/${stepId}/decide`)
      .set('Authorization', `Bearer ${approver1Token}`)
      .send({ decision: 'request_resubmission', decisionNote: 'fix clauses 3-5' });
    expect(res.status).toBe(200);
    expect(res.body.newStepStatus).toBe('resubmission_requested');
    expect(res.body.newContractStatus).toBe('draft');
  });

  it('AC-S2-04: returns 403 when caller is NOT the assigned approver', async () => {
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    const chainId = submit.body.chainId;
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    let stepId: number;
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
    // approver2 (not assigned) tries to decide
    const res = await request(app)
      .post(`/api/v1/approvals/${stepId}/decide`)
      .set('Authorization', `Bearer ${approver2Token}`)
      .send({ decision: 'approve' });
    expect(res.status).toBe(403);
  });

  it('AC-S2-05: returns 409 when step is already decided', async () => {
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    const chainId = submit.body.chainId;
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    let stepId: number;
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
    await request(app)
      .post(`/api/v1/approvals/${stepId}/decide`)
      .set('Authorization', `Bearer ${approver1Token}`)
      .send({ decision: 'approve' });
    const res = await request(app)
      .post(`/api/v1/approvals/${stepId}/decide`)
      .set('Authorization', `Bearer ${approver1Token}`)
      .send({ decision: 'approve' });
    expect(res.status).toBe(409);
  });

  it('AC-S2-06: returns 404 when stepId does not exist', async () => {
    const res = await request(app)
      .post(`/api/v1/approvals/9999999/decide`)
      .set('Authorization', `Bearer ${approver1Token}`)
      .send({ decision: 'approve' });
    expect(res.status).toBe(404);
  });
});

// ============================================================================
// S3 — POST /approvals/:stepId/delegate
// ============================================================================
describe('S3 — POST /api/v1/approvals/:stepId/delegate', () => {
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

  it('AC-S3-01: delegate to compatible role returns 200, step still pending', async () => {
    const res = await request(app)
      .post(`/api/v1/approvals/${stepId}/delegate`)
      .set('Authorization', `Bearer ${approver1Token}`)
      .send({ delegatedToUserId: getFixture('approver2').id });
    expect(res.status).toBe(200);
    expect(Number(res.body.stepId)).toBe(stepId);
    expect(Number(res.body.delegatedTo.id)).toBe(getFixture('approver2').id);
  });

  it('AC-S3-04: self-delegation returns 4xx (controller pre-rejects)', async () => {
    const res = await request(app)
      .post(`/api/v1/approvals/${stepId}/delegate`)
      .set('Authorization', `Bearer ${approver1Token}`)
      .send({ delegatedToUserId: getFixture('approver1').id });
    expect(res.status === 400 || res.status === 403).toBe(true);
  });

  it('AC-S3-05: returns 404 for missing stepId', async () => {
    const res = await request(app)
      .post(`/api/v1/approvals/9999999/delegate`)
      .set('Authorization', `Bearer ${approver1Token}`)
      .send({ delegatedToUserId: getFixture('approver2').id });
    expect(res.status).toBe(404);
  });
});

// ============================================================================
// S1 — GET /approvals/my-pending
// ============================================================================
describe('S1 — GET /api/v1/approvals/my-pending', () => {
  it('AC-S1-01 + AC-S1-07: returns paginated list with required keys', async () => {
    // Submit a fresh contract so approver1 has at least one row.
    const c = await createDraftContract(drafterToken);
    const submit = await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    expect(submit.status).toBe(201);

    const res = await request(app)
      .get('/api/v1/approvals/my-pending?page=1&limit=20&sort=oldest')
      .set('Authorization', `Bearer ${approver1Token}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.pagination).toMatchObject({
      page: 1,
      limit: 20,
    });
    expect(res.body.pagination).toHaveProperty('total');
    expect(res.body.pagination).toHaveProperty('totalPages');
    if (res.body.data.length > 0) {
      const row = res.body.data[0];
      for (const k of ['stepId', 'chainId', 'contractId', 'stepOrder']) {
        expect(row).toHaveProperty(k);
      }
    }
  });

  it('AC-S1-05 + AC-S1-07: empty data + totalPages=0 when caller has no pending', async () => {
    const res = await request(app)
      .get('/api/v1/approvals/my-pending')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(200);
    expect(res.body.data).toEqual([]);
    expect(res.body.pagination.total).toBe(0);
    expect(res.body.pagination.totalPages).toBe(0);
  });

  it('AC-S1-02: invalid sort returns 400', async () => {
    const res = await request(app)
      .get('/api/v1/approvals/my-pending?sort=bogus')
      .set('Authorization', `Bearer ${approver1Token}`);
    expect(res.status).toBe(400);
  });
});

// ============================================================================
// S10 — GET /contracts/:id/approval-chain
// ============================================================================
describe('S10 — GET /api/v1/contracts/:id/approval-chain', () => {
  it('AC-S10-01 + AC-S10-02: returns chain + steps', async () => {
    const c = await createDraftContract(drafterToken);
    await request(app)
      .post(`/api/v1/contracts/${c.id}/submit-for-approval`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});
    const res = await request(app)
      .get(`/api/v1/contracts/${c.id}/approval-chain`)
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(200);
    expect(res.body.chain).toMatchObject({ contractId: c.id, status: 'in_progress' });
    expect(Array.isArray(res.body.steps)).toBe(true);
    expect(res.body.steps.length).toBe(2);
  });

  it('AC-S10-03: 404 when no chain exists for contract', async () => {
    // Fresh contract without submission
    const c = await createDraftContract(drafterToken);
    const res = await request(app)
      .get(`/api/v1/contracts/${c.id}/approval-chain`)
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(404);
  });
});
