/**
 * Admin approval-matrix service — thin DB-passthrough.
 *
 * fn_approval_matrix_set positional binding (db-impl-summary I3):
 *   (p_actor_id, p_contract_type, p_min_value_aed, p_rules, p_max_value_aed DEFAULT NULL)
 * We ALWAYS pass all 5 positional args (valueMax = null when unbounded), so
 * positional binding is safe; named binding would be required only if we
 * skipped the trailing default — which we never do.
 */
import { db } from '../../database/client';
import type {
  ApprovalMatrixListQuery,
  ApprovalMatrixListResponse,
  ApprovalMatrixSetResponse,
  UpdateApprovalMatrixDto,
} from '../../types/approval.types';

/** GET /api/v1/admin/approval-matrix → fn_approval_matrix_list (S4) */
export const list = async (
  actorId: number,
  q: ApprovalMatrixListQuery,
): Promise<ApprovalMatrixListResponse> => {
  const page = q.page ?? 1;
  const limit = q.limit ?? 50;
  return db.callFunction<ApprovalMatrixListResponse>(
    'fn_approval_matrix_list',
    [actorId, page, limit, q.contractType ?? null],
    { actorId },
  );
};

/** PUT /api/v1/admin/approval-matrix → fn_approval_matrix_set (S5) */
export const set = async (
  actorId: number,
  body: UpdateApprovalMatrixDto,
): Promise<ApprovalMatrixSetResponse> => {
  // Positional: (p_actor_id, p_contract_type, p_min_value_aed, p_rules, p_max_value_aed)
  return db.callFunction<ApprovalMatrixSetResponse>(
    'fn_approval_matrix_set',
    [actorId, body.contractType, body.valueMin, body.rules, body.valueMax ?? null],
    { actorId },
  );
};
