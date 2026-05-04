/**
 * M2 — Concurrency tests (Codex-lesson scan list).
 *
 * Targets the BE-001 / TOCTOU family of regressions called out in the M2
 * test brief:
 *
 *   1. Parallel approvers in the same parallel_group race fn_approval_decide.
 *      Both approvers approve concurrently — the SELECT FOR UPDATE on the
 *      step + chain rows must serialise updates so the chain advances exactly
 *      once and no "lost update" occurs (e.g. peer skipped to wrong status).
 *
 *   2. fn_contract_status_update_user races against fn_approval_decide's
 *      internal call to fn_contract_status_update_internal. The SELECT FOR
 *      UPDATE on the contract row added in migration 026 must prevent the
 *      drafter from concurrently flipping contract.status while the engine is
 *      transitioning out of in_approval.
 *
 *   3. fn_approval_route_init lock — concurrent submit-for-approval calls
 *      must result in exactly ONE chain creation (uq_approval_chain_one_active_per_contract
 *      backstop + FOR UPDATE pre-check).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, closeAdminPool } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';
import {
  callFnAs,
  cleanupApprovalArtifacts,
  clearMatrixRulesForContractType,
  readChainRow,
  readContractStatus,
  readStepRow,
  seedMatrixRules,
} from '../helpers/m2-helpers';

const trackedContractIds: number[] = [];
const RUN_ID = `m2cc-${Date.now()}`;
const CONTRACT_TYPE_FOR_TESTS = 'partnership';

beforeAll(async () => {
  await seedFixtureUsers();
});

afterAll(async () => {
  if (trackedContractIds.length > 0) {
    try {
      await cleanupApprovalArtifacts(trackedContractIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M2-concurrency-cleanup] approval artifacts:', err);
    }
    try {
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
      console.warn('[M2-concurrency-cleanup] contract delete:', err);
    }
  }
  try {
    await clearMatrixRulesForContractType(CONTRACT_TYPE_FOR_TESTS);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M2-concurrency-cleanup] matrix:', err);
  }
  await closeAdminPool();
});

const seedDraftContract = async (
  drafterId: number,
  valueAed: number,
): Promise<{ id: number }> => {
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
  return { id: result.id };
};

describe('Concurrency — parallel approvers in same parallel_group race fn_approval_decide', () => {
  it('two simultaneous approves do not corrupt step/chain state (BE-001 SELECT FOR UPDATE)', async () => {
    const drafter = getFixture('drafter1');
    const approver1 = getFixture('approver1');
    const approver2 = getFixture('approver2');

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
          isRequired: true,
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

    // Claim both peer steps to specific approvers.
    const pool = adminPool();
    const client = await pool.connect();
    let stepIds: { contract_approver: number; contract_approver_2: number };
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      const rows = await client.query<{ id: number; approver_role: string }>(
        `SELECT id, approver_role FROM approval_step
          WHERE approval_chain_id = $1 AND step_order = 1`,
        [init.chainId],
      );
      const map: Record<string, number> = {};
      for (const row of rows.rows) map[row.approver_role] = Number(row.id);
      await client.query(
        'UPDATE approval_step SET approver_user_id = $1 WHERE id = $2',
        [approver1.id, map['contract_approver']],
      );
      await client.query(
        'UPDATE approval_step SET approver_user_id = $1 WHERE id = $2',
        [approver2.id, map['contract_approver_2']],
      );
      await client.query('COMMIT');
      stepIds = {
        contract_approver: map['contract_approver']!,
        contract_approver_2: map['contract_approver_2']!,
      };
    } finally {
      client.release();
    }

    // Fire both approves in parallel.
    const [r1, r2] = await Promise.all([
      callFnAs<{ newChainStatus: string; newStepStatus: string }>(
        approver1.id,
        'fn_approval_decide',
        [stepIds.contract_approver, approver1.id, 'approve', null],
      ),
      callFnAs<{ newChainStatus: string; newStepStatus: string }>(
        approver2.id,
        'fn_approval_decide',
        [stepIds.contract_approver_2, approver2.id, 'approve', null],
      ),
    ]);

    // Both step approves succeed. Exactly one of them transitions the chain
    // to 'approved' (whichever lock-acquired second). Both step rows are now
    // 'approved'.
    const finalChain = await readChainRow(init.chainId);
    expect(finalChain!.status).toBe('approved');
    const step1 = await readStepRow(stepIds.contract_approver);
    const step2 = await readStepRow(stepIds.contract_approver_2);
    expect(step1!.status).toBe('approved');
    expect(step2!.status).toBe('approved');
    expect(await readContractStatus(c.id)).toBe('approved');

    // At least one of the two responses reports newChainStatus='approved'.
    const sawApproved = [r1.newChainStatus, r2.newChainStatus].includes('approved');
    expect(sawApproved).toBe(true);
  });
});

describe('Concurrency — fn_approval_route_init duplicate-submit race', () => {
  it('two simultaneous submit-for-approval calls produce exactly ONE chain', async () => {
    const drafter = getFixture('drafter1');
    await seedMatrixRules(
      CONTRACT_TYPE_FOR_TESTS,
      0,
      100_000,
      [{ stepOrder: 1, approverRole: 'contract_approver', isRequired: true }],
      drafter.id,
    );
    const c = await seedDraftContract(drafter.id, 50_000);

    const tasks = [0, 1].map(() =>
      callFnAs<{ chainId: number }>(drafter.id, 'fn_approval_route_init', [
        c.id,
        drafter.id,
      ]).catch((err) => err),
    );
    const results = await Promise.all(tasks);
    // Exactly one resolves; the other is rejected with the duplicate-chain
    // P0001 raise OR the unique-index 23505 backstop.
    const ok = results.filter(
      (r): r is { chainId: number } =>
        typeof r === 'object' && r !== null && 'chainId' in (r as Record<string, unknown>),
    );
    const errs = results.filter((r) => r instanceof Error);
    expect(ok.length).toBe(1);
    expect(errs.length).toBe(1);
    // Either the explicit duplicate-chain raise OR the contract.status-pre-check
    // raise OR the unique-index 23505 backstop is acceptable — all three
    // signal "no second chain". The fn_'s status-precheck happens before the
    // chain-existence pre-check when the contract was already transitioned
    // to in_approval by the racing call.
    expect(String(errs[0])).toMatch(
      /already has an in-progress|duplicate|unique|Invalid transition from in_approval/i,
    );

    // Confirm the DB has only one in_progress chain for this contract.
    const pool = adminPool();
    const client = await pool.connect();
    try {
      const r = await client.query<{ count: string }>(
        `SELECT COUNT(*)::text AS count
           FROM approval_chain
          WHERE contract_id = $1 AND status = 'in_progress' AND is_active = TRUE`,
        [c.id],
      );
      expect(Number(r.rows[0]!.count)).toBe(1);
    } finally {
      client.release();
    }
  });
});

describe('Concurrency — fn_contract_status_update_user vs fn_approval_decide on same contract', () => {
  it('drafter cannot race approver to corrupt in_approval state (FOR UPDATE on contract row)', async () => {
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
        [approver1.id, init.chainId],
      );
      stepId = Number(r.rows[0]!.id);
      await client.query('COMMIT');
    } finally {
      client.release();
    }

    // Fire approver decide + drafter override in parallel.
    const [decideRes, overrideRes] = await Promise.all([
      callFnAs<{ newContractStatus: string }>(approver1.id, 'fn_approval_decide', [
        stepId,
        approver1.id,
        'approve',
        null,
      ]).catch((err) => err),
      callFnAs<{ toStatus: string }>(drafter.id, 'fn_contract_status_update_user', [
        c.id,
        'approved',
        drafter.id,
        null,
      ]).catch((err) => err),
    ]);

    // Approver path always succeeds (it has a legitimate role-based grant).
    expect(decideRes).not.toBeInstanceOf(Error);
    // Drafter direct override is ALWAYS rejected (M2-NEW-1 / AC-S12-02). Either
    // the drafter call ran first while contract was still in_approval (→ 409
    // 'Use fn_approval_decide'), or it ran after the approver finished
    // (→ 'Status is already approved' OR 'Invalid transition from approved
    // to approved'). Either way it must NOT silently succeed.
    expect(overrideRes).toBeInstanceOf(Error);
    expect(String(overrideRes)).toMatch(
      /Use fn_approval_decide|already approved|Invalid transition/i,
    );

    // Contract ends in 'approved' status — written ONCE.
    expect(await readContractStatus(c.id)).toBe('approved');
  });
});

describe('Negative — ERRCODE materialization sanity', () => {
  it('22023 (invalid_parameter_value) raise is caught as such', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_approval_my_pending', [
        drafter.id,
        1,
        20,
        'bogus',
      ]),
    ).rejects.toThrow(/Invalid sort key/i);
  });

  it('P0001 (raise_exception) — duplicate-chain / status guard propagates', async () => {
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
    // The contract is now in_approval; the second submit hits the
    // contract.status pre-check before the chain-existence pre-check. Either
    // P0001 raise is acceptable.
    await expect(
      callFnAs(drafter.id, 'fn_approval_route_init', [c.id, drafter.id]),
    ).rejects.toThrow(/already has an in-progress|Invalid transition from in_approval/i);
  });

  it('P0002 (no_data_found) — Step not found raise propagates', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_approval_decide', [-999, drafter.id, 'approve', null]),
    ).rejects.toThrow(/Step not found/i);
  });

  it('42501 (insufficient_privilege) — fn_approval_route_init rejects no-permission caller', async () => {
    const recipient = getFixture('recipient1');
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    await expect(
      callFnAs(recipient.id, 'fn_approval_route_init', [c.id, recipient.id]),
    ).rejects.toThrow(/permission|approval\.submit_for_review/i);
  });
});
