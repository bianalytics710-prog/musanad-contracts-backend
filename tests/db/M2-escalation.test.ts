/**
 * M2 — S9 fn_approval_escalate (DB-only).
 *
 * Covers AC-S9-01..09:
 *   - AC-S9-01: creates a NEW peer approval_step in the same parallel_group with
 *               approver_role = original.escalation_role, escalation_role=NULL on
 *               the new row (no nested escalation).
 *   - AC-S9-02: inserts approval_decision { decision: 'escalate', metadata: {...} }.
 *   - AC-S9-03: original step.status remains 'pending' (both approvers may now act).
 *   - AC-S9-04: idempotent — second call with the same stepId returns the existing
 *               peer without inserting a duplicate.
 *   - AC-S9-05: returns P0001 when escalation_after_hours has not yet elapsed.
 *   - AC-S9-06: returns P0001 when step.status != 'pending'.
 *   - AC-S9-07: returns P0002 when stepId not found.
 *   - AC-S9-08: SECURITY DEFINER — bypasses approval.escalate role check (no
 *               human user holds approval.escalate).
 *   - AC-S9-09: emits one 'approval_escalated' contract_activity row.
 *
 * Strategy: use the seedChainWithBackdatedStep helper to create a chain + step
 * pair with a controlled created_at so escalation eligibility fires
 * immediately. Direct DB asserts on approval_step / approval_decision /
 * contract_activity for AC verification.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminQuery, closeAdminPool } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';
import {
  callFnAs,
  cleanupApprovalArtifacts,
  countContractActivities,
  readStepRow,
  seedChainWithBackdatedStep,
} from '../helpers/m2-helpers';

const trackedContractIds: number[] = [];
const RUN_ID = `m2esc-${Date.now()}`;

beforeAll(async () => {
  await seedFixtureUsers();
});

afterAll(async () => {
  if (trackedContractIds.length > 0) {
    try {
      await cleanupApprovalArtifacts(trackedContractIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M2-escalation-cleanup] approval artifacts:', err);
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
      console.warn('[M2-escalation-cleanup] contract delete:', err);
    }
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
        contractType: 'consulting',
        language: 'en',
        valueAed,
      },
      drafterId,
    ],
  );
  trackedContractIds.push(result.id);
  return result;
};

describe('S9 — fn_approval_escalate', () => {
  it('AC-S9-01 + AC-S9-02 + AC-S9-03 + AC-S9-09: happy path creates peer step, decision row, and activity', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    const seeded = await seedChainWithBackdatedStep({
      contractId: c.id,
      initiatedBy: drafter.id,
      approverRole: 'contract_approver',
      escalationRole: 'legal_counsel',
      escalationAfterHours: 1,
      backdateHours: 5, // already eligible
    });

    const result = await callFnAs<{
      stepId: number;
      escalationRole: string;
      newPeerStepId: number;
      decisionId: number;
      acted: boolean;
    }>(0, 'fn_approval_escalate', [seeded.stepId]);
    expect(Number(result.stepId)).toBe(seeded.stepId);
    expect(result.escalationRole).toBe('legal_counsel');
    expect(result.newPeerStepId).toBeGreaterThan(0);
    expect(result.decisionId).toBeGreaterThan(0);

    // Original step still pending (AC-S9-03)
    const orig = await readStepRow(seeded.stepId);
    expect(orig!.status).toBe('pending');
    // Promoted to parallel (parallel_group = step_order)
    expect(Number(orig!.parallel_group)).toBe(Number(orig!.step_order));

    // New peer step exists (AC-S9-01)
    const peer = await readStepRow(Number(result.newPeerStepId));
    expect(peer).not.toBeNull();
    expect(peer!.status).toBe('pending');
    expect(peer!.approver_role).toBe('legal_counsel');
    expect(peer!.escalation_role).toBeNull(); // no nested escalation
    expect(Number(peer!.parallel_group)).toBe(Number(orig!.step_order));

    // Approval decision row (AC-S9-02)
    const decisions = await adminQuery<{
      decision: string;
      metadata: Record<string, unknown>;
    }>(
      `SELECT decision, metadata FROM approval_decision
        WHERE id = $1`,
      [result.decisionId],
    );
    expect(decisions[0]).toBeDefined();
    expect(decisions[0]!.decision).toBe('escalate');

    // contract_activity row (AC-S9-09)
    const activityCount = await countContractActivities(c.id, 'approval_escalated');
    expect(activityCount).toBeGreaterThanOrEqual(1);
  });

  it('AC-S9-04: idempotent — re-call returns existing peer without inserting duplicate', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    const seeded = await seedChainWithBackdatedStep({
      contractId: c.id,
      initiatedBy: drafter.id,
      approverRole: 'contract_approver',
      escalationRole: 'legal_counsel',
      escalationAfterHours: 1,
      backdateHours: 5,
    });
    const r1 = await callFnAs<{ newPeerStepId: number; acted: boolean }>(
      0,
      'fn_approval_escalate',
      [seeded.stepId],
    );
    expect(r1.acted).toBe(true);
    const r2 = await callFnAs<{ newPeerStepId: number; acted: boolean; reason?: string }>(
      0,
      'fn_approval_escalate',
      [seeded.stepId],
    );
    expect(Number(r2.newPeerStepId)).toBe(Number(r1.newPeerStepId));
    expect(r2.acted).toBe(false);
    expect(r2.reason).toMatch(/already escalated/i);
  });

  it('AC-S9-05: returns P0001 when escalation_after_hours has not elapsed', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    const seeded = await seedChainWithBackdatedStep({
      contractId: c.id,
      initiatedBy: drafter.id,
      approverRole: 'contract_approver',
      escalationRole: 'legal_counsel',
      escalationAfterHours: 24, // 24h
      backdateHours: 1, // only 1h ago — not eligible
    });
    await expect(
      callFnAs(0, 'fn_approval_escalate', [seeded.stepId]),
    ).rejects.toThrow(/escalation_after_hours has not yet elapsed/i);
  });

  it('AC-S9-06: returns P0001 when step.status != pending', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    const seeded = await seedChainWithBackdatedStep({
      contractId: c.id,
      initiatedBy: drafter.id,
      approverRole: 'contract_approver',
      escalationRole: 'legal_counsel',
      escalationAfterHours: 1,
      backdateHours: 5,
    });
    // Force step to approved (bypass fn for control)
    const { adminPool } = await import('../helpers/m1a-helpers');
    const pool = adminPool();
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      await client.query(
        `UPDATE approval_step SET status = 'approved', decided_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [seeded.stepId],
      );
      await client.query('COMMIT');
    } finally {
      client.release();
    }
    await expect(
      callFnAs(0, 'fn_approval_escalate', [seeded.stepId]),
    ).rejects.toThrow(/Step is not pending/i);
  });

  it('AC-S9-07: returns P0002 when stepId not found', async () => {
    await expect(
      callFnAs(0, 'fn_approval_escalate', [-999]),
    ).rejects.toThrow(/Step not found/i);
  });

  it('AC-S9-08: SECURITY DEFINER — escalation succeeds even when actor (NULL/0) has no approval.* permissions', async () => {
    // Confirms the cron driver (which calls with SYSTEM_ACTOR_ID=0) can
    // escalate without holding any human role permission. The seeded cron
    // user is intentionally NOT created (system-only invocation).
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    const seeded = await seedChainWithBackdatedStep({
      contractId: c.id,
      initiatedBy: drafter.id,
      approverRole: 'contract_approver',
      escalationRole: 'legal_counsel',
      escalationAfterHours: 1,
      backdateHours: 5,
    });
    const r = await callFnAs<{ acted: boolean }>(0, 'fn_approval_escalate', [
      seeded.stepId,
    ]);
    expect(r.acted).toBe(true);
  });

  it('No-op when escalation_role is NULL (no escalation configured)', async () => {
    const drafter = getFixture('drafter1');
    const c = await seedDraftContract(drafter.id, 50_000);
    const seeded = await seedChainWithBackdatedStep({
      contractId: c.id,
      initiatedBy: drafter.id,
      approverRole: 'contract_approver',
      escalationRole: null,
      escalationAfterHours: null,
      backdateHours: 5,
    });
    const r = await callFnAs<{ acted: boolean; reason?: string }>(
      0,
      'fn_approval_escalate',
      [seeded.stepId],
    );
    expect(r.acted).toBe(false);
    expect(r.reason).toMatch(/no escalation configured/i);
  });
});
