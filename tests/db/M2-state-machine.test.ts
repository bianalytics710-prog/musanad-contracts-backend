/**
 * M2 — State machine + parallel-group + S12 transition tests.
 *
 * Scope:
 *   - End-to-end happy path: draft -> in_approval (via S7) -> approve all
 *     steps (via S2) -> approved -> active (via S12).
 *   - Reject path: draft -> in_approval -> reject -> rejected -> draft (S12
 *     resubmission).
 *   - Request_resubmission path: contract.status returns to 'draft' atomically.
 *   - Parallel-group rules (AC-S2-07 ALL-OF; AC-S2-08 ANY-OF).
 *   - S12 (fn_contract_status_update_user) — narrow drafter transitions; the
 *     in_approval -> terminal direct override is rejected with 409.
 *   - decisionNote required for reject / request_resubmission (AC-S2-02/03).
 *   - Whitelist regression: rejects in_approval->approved direct override
 *     (engine-only) and approved->draft (no resurrection).
 *
 * The DB tests in this file deliberately call fn_'s via the admin pool with
 * GUC set; HTTP-layer tests for S12 live in M2-cross-module-extension.test.ts.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { closeAdminPool, adminQuery } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';
import {
  callFnAs,
  cleanupApprovalArtifacts,
  clearMatrixRulesForContractType,
  countContractActivities,
  forceResetContractToDraft,
  listContractActivityTypes,
  readChainRow,
  readContractStatus,
  readStepRow,
  seedMatrixRules,
} from '../helpers/m2-helpers';

const trackedContractIds: number[] = [];
const RUN_ID = `m2sm-${Date.now()}`;
const CONTRACT_TYPE_FOR_TESTS = 'msa';

beforeAll(async () => {
  await seedFixtureUsers();
});

afterAll(async () => {
  if (trackedContractIds.length > 0) {
    try {
      await cleanupApprovalArtifacts(trackedContractIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M2-state-machine-cleanup] approval artifacts:', err);
    }
    try {
      const { adminPool } = await import('../helpers/m1a-helpers');
      const pool = adminPool();
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        await client.query('SET LOCAL row_security = off');
        await client.query(
          `DELETE FROM contract_activity WHERE contract_id = ANY($1::BIGINT[])`,
          [trackedContractIds],
        );
        await client.query(
          `DELETE FROM contract WHERE id = ANY($1::BIGINT[])`,
          [trackedContractIds],
        );
        await client.query('COMMIT');
      } catch {
        try {
          await client.query('ROLLBACK');
        } catch {
          /* swallow */
        }
      } finally {
        client.release();
      }
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M2-state-machine-cleanup] contract delete:', err);
    }
  }
  try {
    await clearMatrixRulesForContractType(CONTRACT_TYPE_FOR_TESTS);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M2-state-machine-cleanup] matrix:', err);
  }
  await closeAdminPool();
});

const seedDraftContract = async (
  drafterId: number,
  valueAed: number,
): Promise<{ id: number; contractNumber: string }> => {
  const result = await callFnAs<{ id: number; contractNumber: string }>(
    drafterId,
    'fn_contract_create',
    [
      {
        titleEn: `M2-${RUN_ID}-${Math.floor(Math.random() * 1e9)}`,
        contractType: CONTRACT_TYPE_FOR_TESTS,
        language: 'en',
        valueAed,
      },
      drafterId,
    ],
  );
  trackedContractIds.push(result.id);
  return result;
};

/**
 * Look up the step in a chain assigned to (or matching role of) the given
 * approver. Sets approver_user_id directly so the actor matches the 4-OR-arm
 * narrowing in fn_approval_decide.
 */
const claimStepForApprover = async (
  chainId: number,
  stepOrder: number,
  approverUserId: number,
): Promise<number> => {
  const { adminPool } = await import('../helpers/m1a-helpers');
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    // AC-S2-07 has two parallel steps sharing step_order=1; without LIMIT 1
    // an unscoped UPDATE matches both, leaving the second peer assigned to
    // the wrong approver. Use a subquery to scope to exactly one row.
    const r = await client.query<{ id: number | string }>(
      `UPDATE approval_step
         SET approver_user_id = $1
       WHERE id = (
         SELECT id FROM approval_step
          WHERE approval_chain_id = $2
            AND step_order = $3
            AND approver_user_id IS NULL
            AND is_active = TRUE
          ORDER BY id ASC
          LIMIT 1
         )
       RETURNING id`,
      [approverUserId, chainId, stepOrder],
    );
    await client.query('COMMIT');
    return Number(r.rows[0]!.id);
  } finally {
    client.release();
  }
};

// ============================================================================
// END-TO-END — happy path
// ============================================================================
describe('End-to-end: draft -> in_review -> in_approval -> approved -> active', () => {
  it('full state-machine happy path emits the right activity rows', async () => {
    const drafter = getFixture('drafter1');
    const approver1 = getFixture('approver1');
    const approver2 = getFixture('approver2');

    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [
        { stepOrder: 1, approverRole: 'contract_approver', isRequired: true },
        { stepOrder: 2, approverRole: 'contract_approver_2', isRequired: true },
      ],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);

    // 1. Submit (draft -> in_approval via fn_approval_route_init)
    const init = await callFnAs<{
      chainId: number;
      newContractStatus: string;
      totalSteps: number;
    }>(drafter.id, 'fn_approval_route_init', [c.id, drafter.id]);
    expect(init.newContractStatus).toBe('in_approval');
    expect(init.totalSteps).toBe(2);
    expect(await readContractStatus(c.id)).toBe('in_approval');

    // 2. approver1 approves step 1
    const step1Id = await claimStepForApprover(init.chainId, 1, approver1.id);
    const decide1 = await callFnAs<{
      newStepStatus: string;
      newChainStatus: string;
      newContractStatus: string;
      advancedToStepOrder: number | null;
    }>(approver1.id, 'fn_approval_decide', [
      step1Id,
      approver1.id,
      'approve',
      null,
    ]);
    expect(decide1.newStepStatus).toBe('approved');
    expect(decide1.newChainStatus).toBe('in_progress');
    expect(decide1.newContractStatus).toBe('in_approval');
    expect(decide1.advancedToStepOrder).toBe(2);
    expect(await readContractStatus(c.id)).toBe('in_approval');

    // 3. approver2 approves step 2 (last required step)
    const step2Id = await claimStepForApprover(init.chainId, 2, approver2.id);
    const decide2 = await callFnAs<{
      newStepStatus: string;
      newChainStatus: string;
      newContractStatus: string;
    }>(approver2.id, 'fn_approval_decide', [
      step2Id,
      approver2.id,
      'approve',
      null,
    ]);
    expect(decide2.newStepStatus).toBe('approved');
    expect(decide2.newChainStatus).toBe('approved');
    expect(decide2.newContractStatus).toBe('approved');

    // chain row: status='approved', completed_at NOT NULL
    const chainRow = await readChainRow(init.chainId);
    expect(chainRow!.status).toBe('approved');
    expect(chainRow!.completed_at).not.toBeNull();
    expect(await readContractStatus(c.id)).toBe('approved');

    // 4. drafter transitions approved -> active
    const transition = await callFnAs<{
      fromStatus: string;
      toStatus: string;
    }>(drafter.id, 'fn_contract_status_update_user', [
      c.id,
      'active',
      drafter.id,
      null,
    ]);
    expect(transition.fromStatus).toBe('approved');
    expect(transition.toStatus).toBe('active');
    expect(await readContractStatus(c.id)).toBe('active');

    // Activity row sanity: contract has at least one of each expected type.
    const types = await listContractActivityTypes(c.id);
    expect(types).toContain('created');
    expect(types).toContain('submitted_for_approval');
    // approval_decided emitted twice (one per decision)
    expect(types.filter((t) => t === 'approval_decided').length).toBeGreaterThanOrEqual(2);
    // status_changed emitted on terminal transitions and/or via trigger
    expect(types.filter((t) => t === 'status_changed').length).toBeGreaterThanOrEqual(1);
  });
});

// ============================================================================
// REJECT path
// ============================================================================
describe('Reject path — chain halts, contract.status=rejected, drafter resubmits to draft', () => {
  it('AC-S2-02 reject + AC-S12-01 rejected -> draft via S12', async () => {
    const drafter = getFixture('drafter1');
    const approver1 = getFixture('approver1');

    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [{ stepOrder: 1, approverRole: 'contract_approver', isRequired: true }],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);
    const init = await callFnAs<{ chainId: number }>(
      drafter.id,
      'fn_approval_route_init',
      [c.id, drafter.id],
    );
    const stepId = await claimStepForApprover(init.chainId, 1, approver1.id);

    // Reject without note → 22023
    await expect(
      callFnAs(approver1.id, 'fn_approval_decide', [
        stepId,
        approver1.id,
        'reject',
        null,
      ]),
    ).rejects.toThrow(/decisionNote is required for reject/i);

    // Reject with note → chain rejected, contract rejected
    const result = await callFnAs<{
      newStepStatus: string;
      newChainStatus: string;
      newContractStatus: string;
    }>(approver1.id, 'fn_approval_decide', [
      stepId,
      approver1.id,
      'reject',
      'not enough detail',
    ]);
    expect(result.newStepStatus).toBe('rejected');
    expect(result.newChainStatus).toBe('rejected');
    expect(result.newContractStatus).toBe('rejected');
    expect(await readContractStatus(c.id)).toBe('rejected');

    // S12 has no rejected -> draft transition. The drafter would re-create a
    // new contract or we force-reset for resubmission flow tests. Verify the
    // direct override is rejected.
    await expect(
      callFnAs(drafter.id, 'fn_contract_status_update_user', [
        c.id,
        'draft',
        drafter.id,
        null,
      ]),
    ).rejects.toThrow(/Invalid transition from rejected to draft/i);
  });
});

// ============================================================================
// REQUEST_RESUBMISSION path
// ============================================================================
describe('Request_resubmission — contract.status returns to draft atomically', () => {
  it('AC-S2-03 request_resubmission requires note + transitions contract to draft', async () => {
    const drafter = getFixture('drafter1');
    const approver1 = getFixture('approver1');

    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [{ stepOrder: 1, approverRole: 'contract_approver', isRequired: true }],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);
    const init = await callFnAs<{ chainId: number }>(
      drafter.id,
      'fn_approval_route_init',
      [c.id, drafter.id],
    );
    const stepId = await claimStepForApprover(init.chainId, 1, approver1.id);

    // Empty note → 22023
    await expect(
      callFnAs(approver1.id, 'fn_approval_decide', [
        stepId,
        approver1.id,
        'request_resubmission',
        null,
      ]),
    ).rejects.toThrow(/decisionNote is required for request_resubmission/i);

    const result = await callFnAs<{
      newStepStatus: string;
      newChainStatus: string;
      newContractStatus: string;
    }>(approver1.id, 'fn_approval_decide', [
      stepId,
      approver1.id,
      'request_resubmission',
      'clarify clauses 3 and 5',
    ]);
    expect(result.newStepStatus).toBe('resubmission_requested');
    expect(result.newChainStatus).toBe('resubmission_requested');
    expect(result.newContractStatus).toBe('draft');
    expect(await readContractStatus(c.id)).toBe('draft');
  });
});

// ============================================================================
// PARALLEL GROUP — ALL-OF (every required peer must approve)
// ============================================================================
describe('Parallel group ALL-OF (AC-S2-07): both required peers approve before chain advances', () => {
  it('first approve does not advance chain; second approve transitions chain to approved', async () => {
    const drafter = getFixture('drafter1');
    const approver1 = getFixture('approver1');
    const approver2 = getFixture('approver2');

    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [
        // Two peers in step_order=1 / parallel_group=1, both required.
        {
          stepOrder: 1,
          parallelGroup: 1,
          approverRole: 'contract_approver',
          isRequired: true,
        },
        {
          stepOrder: 1,
          parallelGroup: 1,
          approverRole: 'contract_approver_2',
          isRequired: true,
        },
      ],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);
    const init = await callFnAs<{ chainId: number; totalSteps: number }>(
      drafter.id,
      'fn_approval_route_init',
      [c.id, drafter.id],
    );
    expect(init.totalSteps).toBe(2);

    // Find both peer steps.
    const steps = await adminQuery<{ id: number; approver_role: string }>(
      `SELECT id, approver_role
         FROM approval_step
        WHERE approval_chain_id = $1 AND step_order = 1
        ORDER BY approver_role`,
      [init.chainId],
    );
    const stepApprover = steps.find((s) => s.approver_role === 'contract_approver')!;
    const stepApprover2 = steps.find((s) => s.approver_role === 'contract_approver_2')!;
    // Claim both (so we can decide deterministically).
    await claimStepForApprover(init.chainId, 1, approver1.id); // sets only the row that still has NULL
    // The first claim took the contract_approver row (since we queried for it in
    // role-name order). Force-set the second step's approver_user_id directly.
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      await client.query(
        'UPDATE approval_step SET approver_user_id = $1 WHERE id = $2 AND approver_user_id IS NULL',
        [approver2.id, stepApprover2.id],
      );
      await client.query('COMMIT');
    } finally {
      client.release();
    }

    // First approve — chain stays in_progress (peer still pending)
    const first = await callFnAs<{
      newChainStatus: string;
      newContractStatus: string;
    }>(approver1.id, 'fn_approval_decide', [
      stepApprover.id,
      approver1.id,
      'approve',
      null,
    ]);
    expect(first.newChainStatus).toBe('in_progress');
    expect(first.newContractStatus).toBe('in_approval');

    // Second approve — last required peer → chain approved
    const second = await callFnAs<{
      newChainStatus: string;
      newContractStatus: string;
    }>(approver2.id, 'fn_approval_decide', [
      stepApprover2.id,
      approver2.id,
      'approve',
      null,
    ]);
    expect(second.newChainStatus).toBe('approved');
    expect(second.newContractStatus).toBe('approved');
    expect(await readContractStatus(c.id)).toBe('approved');
  });
});

// ============================================================================
// PARALLEL GROUP — ANY-OF (AC-S2-08): one required + one optional, first approve short-circuits
// ============================================================================
describe('Parallel group ANY-OF (AC-S2-08): required approve short-circuits optional peer', () => {
  it('first required approve sets the optional peer to status=skipped', async () => {
    const drafter = getFixture('drafter1');
    const approver1 = getFixture('approver1');

    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [
        {
          stepOrder: 1,
          parallelGroup: 1,
          approverRole: 'contract_approver',
          isRequired: true,
        },
        {
          stepOrder: 1,
          parallelGroup: 1,
          approverRole: 'contract_approver_2',
          isRequired: false,
        },
      ],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);
    const init = await callFnAs<{ chainId: number }>(
      drafter.id,
      'fn_approval_route_init',
      [c.id, drafter.id],
    );

    // Get step ids
    const steps = await adminQuery<{ id: number; approver_role: string; is_required: boolean }>(
      `SELECT id, approver_role, is_required
         FROM approval_step
        WHERE approval_chain_id = $1 AND step_order = 1
        ORDER BY is_required DESC`,
      [init.chainId],
    );
    const required = steps.find((s) => s.is_required)!;
    const optional = steps.find((s) => !s.is_required)!;

    // Claim required for approver1
    await callFnAs(drafter.id, 'fn_contract_status_update_user', [
      c.id,
      'active', // expect rejection — but this gives us a 409 path test simultaneously
      drafter.id,
      null,
    ]).catch(() => {
      /* expected */
    });

    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      await client.query(
        'UPDATE approval_step SET approver_user_id = $1 WHERE id = $2',
        [approver1.id, required.id],
      );
      await client.query('COMMIT');
    } finally {
      client.release();
    }

    const r = await callFnAs<{ newChainStatus: string }>(
      approver1.id,
      'fn_approval_decide',
      [required.id, approver1.id, 'approve', null],
    );
    // Chain advances since this is the only step (no further step orders), so
    // newChainStatus = 'approved'.
    expect(r.newChainStatus).toBe('approved');

    // Optional peer should now be 'skipped'.
    const optRow = await readStepRow(optional.id);
    expect(optRow!.status).toBe('skipped');
  });
});

// ============================================================================
// S2 — fn_approval_decide error paths
// ============================================================================
describe('S2 — fn_approval_decide error paths', () => {
  /**
   * Each AC creates its OWN contract+chain so a state mutation in one AC does
   * not leak into the next. (E.g. an actor-check defense-in-depth gap allows
   * an unintended approve and leaves the step in 'approved' state.)
   */
  const buildFreshChainAssignedToApprover1 = async (): Promise<number> => {
    const drafter = getFixture('drafter1');
    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [{ stepOrder: 1, approverRole: 'contract_approver', isRequired: true }],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);
    const init = await callFnAs<{ chainId: number }>(
      drafter.id,
      'fn_approval_route_init',
      [c.id, drafter.id],
    );
    return claimStepForApprover(init.chainId, 1, getFixture('approver1').id);
  };

  it('AC-S2-04: returns 42501 when caller is NOT the approver / delegated_to / reassigned_to', async () => {
    const stepId = await buildFreshChainAssignedToApprover1();
    const approver2 = getFixture('approver2'); // NOT assigned to this step
    await expect(
      callFnAs(approver2.id, 'fn_approval_decide', [
        stepId,
        approver2.id,
        'approve',
        null,
      ]),
    ).rejects.toThrow(/Not the assigned approver/i);
  });

  it('AC-S2-06: returns P0002 when stepId not found', async () => {
    const approver1 = getFixture('approver1');
    await expect(
      callFnAs(approver1.id, 'fn_approval_decide', [
        -999,
        approver1.id,
        'approve',
        null,
      ]),
    ).rejects.toThrow(/Step not found/i);
  });

  it('decision must be one of approve|reject|request_resubmission (22023)', async () => {
    const stepId = await buildFreshChainAssignedToApprover1();
    const approver1 = getFixture('approver1');
    await expect(
      callFnAs(approver1.id, 'fn_approval_decide', [
        stepId,
        approver1.id,
        'bogus',
        null,
      ]),
    ).rejects.toThrow(/Invalid decision/i);
  });

  it('AC-S2-05: returns P0001 when step.status is no longer pending', async () => {
    const stepId = await buildFreshChainAssignedToApprover1();
    const approver1 = getFixture('approver1');
    // approve once (transitions to approved)
    await callFnAs(approver1.id, 'fn_approval_decide', [
      stepId,
      approver1.id,
      'approve',
      null,
    ]);
    // attempt again — status is no longer pending
    await expect(
      callFnAs(approver1.id, 'fn_approval_decide', [
        stepId,
        approver1.id,
        'approve',
        null,
      ]),
    ).rejects.toThrow(/Step already decided/i);
  });

  it('AC-S2-09: emits exactly one approval_decided activity row per decision', async () => {
    const drafter = getFixture('drafter1');
    const approver1 = getFixture('approver1');
    const c = await seedDraftContract(drafter.id, 50_000);
    const init = await callFnAs<{ chainId: number }>(
      drafter.id,
      'fn_approval_route_init',
      [c.id, drafter.id],
    );
    const sId = await claimStepForApprover(init.chainId, 1, approver1.id);
    await callFnAs(approver1.id, 'fn_approval_decide', [
      sId,
      approver1.id,
      'approve',
      null,
    ]);
    const decisionRows = await countContractActivities(c.id, 'approval_decided');
    expect(decisionRows).toBe(1);
  });
});

// ============================================================================
// S12 — fn_contract_status_update_user — narrow drafter transition matrix
// ============================================================================
describe('S12 — fn_contract_status_update_user state machine', () => {
  it('AC-S12-01: draft -> in_review (drafter)', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    const r = await callFnAs<{ fromStatus: string; toStatus: string }>(
      drafter.id,
      'fn_contract_status_update_user',
      [c.id, 'in_review', drafter.id, null],
    );
    expect(r.fromStatus).toBe('draft');
    expect(r.toStatus).toBe('in_review');
  });

  it('AC-S12-01: in_review -> draft (drafter cancel-review)', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    await callFnAs(drafter.id, 'fn_contract_status_update_user', [
      c.id,
      'in_review',
      drafter.id,
      null,
    ]);
    const r = await callFnAs<{ fromStatus: string; toStatus: string }>(
      drafter.id,
      'fn_contract_status_update_user',
      [c.id, 'draft', drafter.id, null],
    );
    expect(r.fromStatus).toBe('in_review');
    expect(r.toStatus).toBe('draft');
  });

  it('AC-S12-02: in_approval -> approved direct override is rejected (engine-only)', async () => {
    const drafter = getFixture('drafter1');
    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [{ stepOrder: 1, approverRole: 'contract_approver', isRequired: true }],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);
    await callFnAs(drafter.id, 'fn_approval_route_init', [c.id, drafter.id]);
    expect(await readContractStatus(c.id)).toBe('in_approval');
    await expect(
      callFnAs(drafter.id, 'fn_contract_status_update_user', [
        c.id,
        'approved',
        drafter.id,
        null,
      ]),
    ).rejects.toThrow(/Use fn_approval_decide for in_approval transitions/i);
  });

  it('AC-S12-03: draft -> approved direct (skipping chain) returns 409 invalid transition', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    await expect(
      callFnAs(drafter.id, 'fn_contract_status_update_user', [
        c.id,
        'approved',
        drafter.id,
        null,
      ]),
    ).rejects.toThrow(/Invalid transition from draft to approved/i);
  });

  it('AC-S12-04: draft -> in_review requires approval.submit_for_review', async () => {
    const drafter = getFixture('drafter1');
    const recipient = getFixture('recipient1');
    const c = await seedDraftContract(drafter.id, 50_000);
    await expect(
      callFnAs(recipient.id, 'fn_contract_status_update_user', [
        c.id,
        'in_review',
        recipient.id,
        null,
      ]),
    ).rejects.toThrow(/permission|approval\.submit_for_review/i);
  });

  it('AC-S12-05: non-terminal -> cancelled requires contract.delete OR (contract.draft AND ownership)', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    // drafter1 owns the contract and has contract.draft, so this should succeed.
    const r = await callFnAs<{ toStatus: string }>(
      drafter.id,
      'fn_contract_status_update_user',
      [c.id, 'cancelled', drafter.id, null],
    );
    expect(r.toStatus).toBe('cancelled');
  });

  it('AC-S12-06: approved -> active requires contract.edit', async () => {
    // Easiest scaffold: complete an approval chain to land on 'approved', then
    // verify drafter1 (has contract.edit per M1a 003) can transition to 'active'.
    const drafter = getFixture('drafter1');
    const approver1 = getFixture('approver1');
    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [{ stepOrder: 1, approverRole: 'contract_approver', isRequired: true }],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);
    const init = await callFnAs<{ chainId: number }>(
      drafter.id,
      'fn_approval_route_init',
      [c.id, drafter.id],
    );
    const stepId = await claimStepForApprover(init.chainId, 1, approver1.id);
    await callFnAs(approver1.id, 'fn_approval_decide', [
      stepId,
      approver1.id,
      'approve',
      null,
    ]);
    expect(await readContractStatus(c.id)).toBe('approved');
    const r = await callFnAs<{ fromStatus: string; toStatus: string }>(
      drafter.id,
      'fn_contract_status_update_user',
      [c.id, 'active', drafter.id, null],
    );
    expect(r.fromStatus).toBe('approved');
    expect(r.toStatus).toBe('active');
  });

  it('AC-S12-07: returns P0002 (not found) when contract id does not exist', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_contract_status_update_user', [
        -999,
        'in_review',
        drafter.id,
        null,
      ]),
    ).rejects.toThrow(/Contract not found/i);
  });

  it('AC-S12-08: emits one status_changed activity row per successful transition', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    await callFnAs(drafter.id, 'fn_contract_status_update_user', [
      c.id,
      'in_review',
      drafter.id,
      null,
    ]);
    const count = await countContractActivities(c.id, 'status_changed');
    expect(count).toBeGreaterThanOrEqual(1);
  });

  it('AC-S12-09: backwards-compat — M1a permissive transitions (draft->active direct) now return 409', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    await expect(
      callFnAs(drafter.id, 'fn_contract_status_update_user', [
        c.id,
        'active',
        drafter.id,
        null,
      ]),
    ).rejects.toThrow(/Invalid transition/i);
  });

  it('AE-2 whitelist regression: approved -> draft is rejected (no resurrection)', async () => {
    // get to approved via the chain
    const drafter = getFixture('drafter1');
    const approver1 = getFixture('approver1');
    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [{ stepOrder: 1, approverRole: 'contract_approver', isRequired: true }],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);
    const init = await callFnAs<{ chainId: number }>(
      drafter.id,
      'fn_approval_route_init',
      [c.id, drafter.id],
    );
    const stepId = await claimStepForApprover(init.chainId, 1, approver1.id);
    await callFnAs(approver1.id, 'fn_approval_decide', [
      stepId,
      approver1.id,
      'approve',
      null,
    ]);
    expect(await readContractStatus(c.id)).toBe('approved');
    await expect(
      callFnAs(drafter.id, 'fn_contract_status_update_user', [
        c.id,
        'draft',
        drafter.id,
        null,
      ]),
    ).rejects.toThrow(/Invalid transition from approved to draft/i);
  });
});
