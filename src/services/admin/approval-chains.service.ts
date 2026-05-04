/**
 * Admin approval-chains service — thin DB-passthrough.
 *
 * Covers:
 *   - GET  /api/v1/admin/approval-chains          → fn_approval_chain_list (S11)
 *   - POST /api/v1/admin/approval-steps/:stepId/reassign → fn_approval_reassign (S8)
 */
import { db } from '../../database/client';
import type {
  ApprovalChainListQuery,
  ApprovalChainListResponse,
  ReassignApprovalDto,
  ReassignApprovalResponse,
} from '../../types/approval.types';

/** GET /api/v1/admin/approval-chains → fn_approval_chain_list (S11) */
export const list = async (
  actorId: number,
  q: ApprovalChainListQuery,
): Promise<ApprovalChainListResponse> => {
  const page = q.page ?? 1;
  const limit = q.limit ?? 20;
  return db.callFunction<ApprovalChainListResponse>(
    'fn_approval_chain_list',
    [
      actorId,
      page,
      limit,
      q.contractId ?? null,
      q.status ?? null,
      q.submittedBy ?? null,
    ],
    { actorId },
  );
};

/** POST /api/v1/admin/approval-steps/:stepId/reassign → fn_approval_reassign (S8) */
export const reassign = async (
  actorId: number,
  stepId: number,
  body: ReassignApprovalDto,
): Promise<ReassignApprovalResponse> => {
  return db.callFunction<ReassignApprovalResponse>(
    'fn_approval_reassign',
    [stepId, actorId, body.reassignedToUserId, body.decisionNote ?? null],
    { actorId },
  );
};
