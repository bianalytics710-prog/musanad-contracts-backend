/**
 * Approval workflow service — drafter / approver actions.
 *
 * Thin DB-passthrough; no business logic. Each method calls a single fn_
 * via db.callFunction and returns the parsed JSONB.
 *
 * fn_ parameter binding note (db-impl-summary I2 / I3):
 *   - fn_approval_chain_get    (p_actor_id, p_chain_id DEFAULT NULL, p_contract_id DEFAULT NULL)
 *   - fn_approval_matrix_set   (p_actor_id, p_contract_type, p_min_value_aed, p_rules,
 *                              p_max_value_aed DEFAULT NULL)
 *   We always pass every positional argument (NULL where the caller wants
 *   the DB default) so positional binding remains safe. Postgres requires
 *   DEFAULT params to follow non-DEFAULT params; the actual ordering above
 *   matches the migration source.
 */
import { db } from '../database/client';
import type {
  ApprovalChainGetResponse,
  ApprovalEscalateResponse,
  ApprovalPendingSort,
  DecideApprovalDto,
  DecideApprovalResponse,
  DelegateApprovalDto,
  DelegateApprovalResponse,
  MyPendingApprovalListQuery,
  MyPendingApprovalListResponse,
  ReassignApprovalDto,
  ReassignApprovalResponse,
  RouteInitPreviewRequest,
  RouteInitPreviewResponse,
  SubmitForApprovalResponse,
} from '../types/approval.types';

/** GET /api/v1/approvals/my-pending → fn_approval_my_pending (S1) */
export const listMyPending = async (
  actorId: number,
  q: MyPendingApprovalListQuery,
): Promise<MyPendingApprovalListResponse> => {
  const page: number = q.page ?? 1;
  const limit: number = q.limit ?? 20;
  const sort: ApprovalPendingSort = q.sort ?? 'oldest';
  return db.callFunction<MyPendingApprovalListResponse>(
    'fn_approval_my_pending',
    [actorId, page, limit, sort],
    { actorId },
  );
};

/** POST /api/v1/approvals/:stepId/decide → fn_approval_decide (S2) */
export const decide = async (
  actorId: number,
  stepId: number,
  body: DecideApprovalDto,
): Promise<DecideApprovalResponse> => {
  return db.callFunction<DecideApprovalResponse>(
    'fn_approval_decide',
    [stepId, actorId, body.decision, body.decisionNote ?? null],
    { actorId },
  );
};

/** POST /api/v1/approvals/:stepId/delegate → fn_approval_delegate (S3) */
export const delegate = async (
  actorId: number,
  stepId: number,
  body: DelegateApprovalDto,
): Promise<DelegateApprovalResponse> => {
  return db.callFunction<DelegateApprovalResponse>(
    'fn_approval_delegate',
    [stepId, actorId, body.delegatedToUserId, body.decisionNote ?? null],
    { actorId },
  );
};

/** POST /api/v1/contracts/:id/approval-chain/preview → fn_approval_route_init_preview (S6) */
export const routeInitPreview = async (
  actorId: number,
  body: RouteInitPreviewRequest,
): Promise<RouteInitPreviewResponse> => {
  return db.callFunction<RouteInitPreviewResponse>(
    'fn_approval_route_init_preview',
    [actorId, body.contractType, body.valueAed],
    { actorId },
  );
};

/** POST /api/v1/contracts/:id/submit-for-approval → fn_approval_route_init (S7) */
export const routeInit = async (
  actorId: number,
  contractId: number,
): Promise<SubmitForApprovalResponse> => {
  return db.callFunction<SubmitForApprovalResponse>(
    'fn_approval_route_init',
    [contractId, actorId],
    { actorId },
  );
};

/** GET /api/v1/contracts/:id/approval-chain → fn_approval_chain_get (S10) */
export const chainGetByContractId = async (
  actorId: number,
  contractId: number,
): Promise<ApprovalChainGetResponse | null> => {
  // Positional: (p_actor_id, p_chain_id, p_contract_id) — explicit nulls
  // for the DEFAULT trailing params keep us safe (I2 / I3).
  return db.callFunction<ApprovalChainGetResponse | null>(
    'fn_approval_chain_get',
    [actorId, null, contractId],
    { actorId },
  );
};

/**
 * fn_approval_escalate (S9) — invoked only by the cron driver
 * (src/services/approval-escalation.cron.service.ts). Surfaced here so the
 * driver imports a single service entry point.
 */
export const escalate = async (
  actorId: number,
  stepId: number,
): Promise<ApprovalEscalateResponse> => {
  return db.callFunction<ApprovalEscalateResponse>(
    'fn_approval_escalate',
    [stepId],
    { actorId },
  );
};
