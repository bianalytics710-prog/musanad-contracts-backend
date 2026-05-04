/**
 * Shared helpers for M2 (Approval Workflows) integration + DB function tests.
 *
 * Provides:
 *   - callFnAs()                       — call a fn_ via the BYPASSRLS admin
 *                                        pool with `app.current_user_id` set
 *                                        (mirrors what BE controllers do).
 *   - seedMatrixRules()                — direct INSERT on approval_matrix
 *                                        (skips fn_approval_matrix_set so DB
 *                                        tests can preconfigure rules without
 *                                        being gated by approval.matrix.write).
 *   - clearMatrixRulesForContractType  — afterAll cleanup; hard-deletes any
 *                                        seeded matrix rows for a given type.
 *   - cleanupApprovalArtifacts()       — hard-delete approval_decision +
 *                                        approval_step + approval_chain rows
 *                                        for a list of contract ids.
 *   - resetContractToDraft()           — bypass-RLS UPDATE that returns a
 *                                        contract to status='draft' so a test
 *                                        can re-submit it (used to share fixture
 *                                        contracts across test cases).
 *   - createPendingStepWithEscalation  — directly INSERTs a chain + step pair
 *                                        with controlled created_at so the S9
 *                                        escalation tests can assert behaviour
 *                                        without sleeping for hours.
 *
 * The approval namespace has NO public seed (db-design.md §7.1). Tests must
 * configure approval_matrix rules per scenario.
 *
 * NOTE: M2 tests reuse the m1c fixture user pool (drafter1, approver1,
 *       approver2, recipient1, executive1, legal_counsel1) — see m1c-helpers.
 */
import { adminPool, adminQuery } from './m1a-helpers';

/**
 * Run a fn_ directly with `app.current_user_id` set to the supplied actor id.
 * Mirrors what the BE controller layer does per request. Used by db tests to
 * exercise fn_ permission gates that consult fn_current_user_has_permission.
 */
export const callFnAs = async <T>(
  actorId: number,
  fnName: string,
  args: ReadonlyArray<unknown>,
): Promise<T> => {
  if (!/^[a-z_][a-z0-9_]*$/i.test(fnName)) {
    throw new Error(`bad fn name: ${fnName}`);
  }
  const placeholders = args.map((_, i) => `$${i + 1}`).join(', ');
  const sql = `SELECT ${fnName}(${placeholders}) AS result`;
  const bound = args.map((v) => {
    if (v === undefined || v === null) return null;
    if (Array.isArray(v)) {
      const containsObj = v.some(
        (el) => el !== null && typeof el === 'object' && !(el instanceof Date),
      );
      return containsObj ? JSON.stringify(v) : v;
    }
    if (typeof v === 'object' && !(v instanceof Date)) return JSON.stringify(v);
    return v;
  });
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [
      String(actorId),
    ]);
    const r = await client.query<{ result: T }>(sql, bound);
    await client.query('COMMIT');
    return r.rows[0]!.result as T;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

export interface SeedMatrixRule {
  stepOrder: number;
  parallelGroup?: number | null;
  approverRole: string;
  isRequired?: boolean;
  escalationRole?: string | null;
  escalationAfterHours?: number | null;
}

/**
 * Direct seed of approval_matrix rows via BYPASSRLS pool. Used by DB tests
 * to preconfigure rules without the approval.matrix.write permission gate
 * (those gates are exercised separately by the HTTP S5 tests).
 *
 * Returns the inserted rule ids in the order supplied.
 */
export const seedMatrixRules = async (
  contractType: string,
  minValueAed: number,
  maxValueAed: number | null,
  rules: SeedMatrixRule[],
  createdByUserId: number,
): Promise<number[]> => {
  const pool = adminPool();
  const client = await pool.connect();
  const ids: number[] = [];
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    // Soft-delete any conflicting rules first so the unique index
    // uq_approval_matrix_active_rule does not fire.
    await client.query(
      `UPDATE approval_matrix
          SET is_active = FALSE
        WHERE contract_type = $1
          AND min_value_aed = $2
          AND COALESCE(max_value_aed, -1) = COALESCE($3::numeric, -1)
          AND is_active = TRUE`,
      [contractType, minValueAed, maxValueAed],
    );
    for (const r of rules) {
      const res = await client.query<{ id: number | string }>(
        `INSERT INTO approval_matrix (
            contract_type, min_value_aed, max_value_aed,
            step_order, parallel_group, approver_role,
            is_required, escalation_role, escalation_after_hours,
            created_by, updated_by, is_active
          ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$10,TRUE)
          RETURNING id`,
        [
          contractType,
          minValueAed,
          maxValueAed,
          r.stepOrder,
          r.parallelGroup ?? null,
          r.approverRole,
          r.isRequired ?? true,
          r.escalationRole ?? null,
          r.escalationAfterHours ?? null,
          createdByUserId,
        ],
      );
      ids.push(Number(res.rows[0]!.id));
    }
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
  return ids;
};

/**
 * Hard-delete any approval_matrix rules for a contract_type — afterAll
 * cleanup. The unique index on active rules means tests must clear active
 * rows between runs to avoid clobbering each other.
 */
export const clearMatrixRulesForContractType = async (
  contractType: string,
): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      'DELETE FROM approval_matrix WHERE contract_type = $1',
      [contractType],
    );
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Hard-delete approval_decision + approval_step + approval_chain rows for the
 * given contract ids. Called from afterAll; safe on an empty list.
 *
 * Uses the BYPASSRLS pool so RESTRICTIVE policies don't block the delete.
 */
export const cleanupApprovalArtifacts = async (
  contractIds: number[],
): Promise<void> => {
  if (contractIds.length === 0) return;
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      `DELETE FROM approval_decision d
        USING approval_step s, approval_chain ch
        WHERE d.approval_step_id = s.id
          AND s.approval_chain_id = ch.id
          AND ch.contract_id = ANY($1::BIGINT[])`,
      [contractIds],
    );
    await client.query(
      `DELETE FROM approval_step s
        USING approval_chain ch
        WHERE s.approval_chain_id = ch.id
          AND ch.contract_id = ANY($1::BIGINT[])`,
      [contractIds],
    );
    await client.query(
      'DELETE FROM approval_chain WHERE contract_id = ANY($1::BIGINT[])',
      [contractIds],
    );
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Force-reset a contract to status='draft' bypassing fn_contract_status_update_user.
 *
 * Why this exists: fn_contract_status_update_user enforces a narrow whitelist
 * (M2 / AC-S12-01). Tests that exercise the chain lifecycle need to land back
 * at 'draft' across multiple test cases on the same fixture contract — but the
 * legitimate path requires a chain to terminate. To avoid creating a fresh
 * contract per test, we use the bypass-RLS pool to UPDATE the row directly.
 *
 * Approval artifacts are cleaned separately via cleanupApprovalArtifacts().
 */
export const forceResetContractToDraft = async (
  contractId: number,
): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      `UPDATE contract
          SET status = 'draft',
              updated_at = CURRENT_TIMESTAMP
        WHERE id = $1`,
      [contractId],
    );
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Insert a chain + a single pending step with a backdated created_at so the
 * S9 escalation tests can fire fn_approval_escalate without waiting hours.
 *
 * Returns { chainId, stepId }.
 */
export const seedChainWithBackdatedStep = async (params: {
  contractId: number;
  initiatedBy: number;
  approverRole: string;
  escalationRole: string | null;
  escalationAfterHours: number | null;
  /** How many hours ago to backdate created_at. */
  backdateHours: number;
}): Promise<{ chainId: number; stepId: number }> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const chain = await client.query<{ id: number | string }>(
      `INSERT INTO approval_chain
         (contract_id, matrix_snapshot, status, current_step_order,
          initiated_by, initiated_at, created_by, updated_by, is_active)
         VALUES ($1, '[]'::jsonb, 'in_progress', 1, $2, CURRENT_TIMESTAMP, $2, $2, TRUE)
       RETURNING id`,
      [params.contractId, params.initiatedBy],
    );
    const chainId = Number(chain.rows[0]!.id);
    const step = await client.query<{ id: number | string }>(
      `INSERT INTO approval_step
         (approval_chain_id, step_order, parallel_group,
          approver_user_id, approver_role,
          is_required, escalation_role, escalation_after_hours,
          status, created_by, updated_by, is_active,
          created_at, updated_at)
         VALUES ($1, 1, NULL,
                 NULL, $2,
                 TRUE, $3, $4,
                 'pending', $5, $5, TRUE,
                 CURRENT_TIMESTAMP - make_interval(hours => $6),
                 CURRENT_TIMESTAMP - make_interval(hours => $6))
       RETURNING id`,
      [
        chainId,
        params.approverRole,
        params.escalationRole,
        params.escalationAfterHours,
        params.initiatedBy,
        params.backdateHours,
      ],
    );
    const stepId = Number(step.rows[0]!.id);
    // Also push the contract into in_approval to keep state consistent with
    // fn_approval_route_init's normal post-condition.
    await client.query(
      `UPDATE contract SET status = 'in_approval', updated_at = CURRENT_TIMESTAMP WHERE id = $1`,
      [params.contractId],
    );
    await client.query('COMMIT');
    return { chainId, stepId };
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Read approval_step by id (BYPASSRLS) for assertions.
 */
export const readStepRow = async (
  stepId: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, approval_chain_id, step_order, parallel_group,
            approver_user_id, approver_role, is_required,
            escalation_role, escalation_after_hours,
            status, decided_at, delegated_to, reassigned_to,
            is_active
       FROM approval_step
      WHERE id = $1`,
    [stepId],
  );
  return rows[0] ?? null;
};

/**
 * Read approval_chain by id (BYPASSRLS) for assertions.
 */
export const readChainRow = async (
  chainId: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, contract_id, status, current_step_order,
            initiated_by, initiated_at, completed_at, is_active
       FROM approval_chain
      WHERE id = $1`,
    [chainId],
  );
  return rows[0] ?? null;
};

/**
 * Read contract.status by id (BYPASSRLS).
 */
export const readContractStatus = async (
  contractId: number,
): Promise<string | null> => {
  const rows = await adminQuery<{ status: string }>(
    'SELECT status FROM contract WHERE id = $1',
    [contractId],
  );
  return rows[0]?.status ?? null;
};

/**
 * Count contract_activity rows for a contract by activity_type. Used to
 * verify single emission per AC (S2-09 / S7-08 / S8-08 / S9-09).
 */
export const countContractActivities = async (
  contractId: number,
  activityType: string,
): Promise<number> => {
  const rows = await adminQuery<{ count: string }>(
    `SELECT COUNT(*)::text AS count
       FROM contract_activity
      WHERE contract_id = $1 AND activity_type = $2`,
    [contractId, activityType],
  );
  return Number(rows[0]?.count ?? 0);
};

/**
 * Read all contract_activity activity_type values for a contract, ordered by
 * created_at ASC. Used for state-machine end-to-end ordering assertions.
 */
export const listContractActivityTypes = async (
  contractId: number,
): Promise<string[]> => {
  const rows = await adminQuery<{ activity_type: string }>(
    `SELECT activity_type
       FROM contract_activity
      WHERE contract_id = $1
      ORDER BY created_at ASC, id ASC`,
    [contractId],
  );
  return rows.map((r) => r.activity_type);
};

/**
 * Read approval_decision rows for a step (ordered by id ASC).
 */
export const listDecisionsForStep = async (
  stepId: number,
): Promise<Array<Record<string, unknown>>> => {
  return adminQuery<Record<string, unknown>>(
    `SELECT id, approval_step_id, decision, decided_by, decision_note,
            delegated_to_user_id, reassigned_to_user_id, metadata,
            decided_at
       FROM approval_decision
      WHERE approval_step_id = $1
      ORDER BY id ASC`,
    [stepId],
  );
};
