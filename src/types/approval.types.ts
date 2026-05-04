// ============================================================
// M2 — Approval Workflows — TypeScript Type Definitions
// ============================================================
// Mirrors workspace types.ts (Agent 5 generated). Re-exported by the BE
// controller / service layer. JSONB output keys are camelCase — TS keys
// mirror those. Sensitive fields (decisionNote, matrixSnapshot) are pino-
// redacted at the wire layer; they ARE present on response shapes for
// admin / forensic paths.
// ============================================================

import type { Paginated } from './api.types';
import type {
  ContractStatus as M1aContractStatus,
  ActivityType as M1aActivityType,
  UserRef,
} from './contracts.types';

// ------------------------------------------------------------
// 1. Cross-module union extensions (AE-1 + AE-3)
// ------------------------------------------------------------

/** AE-3 — Contract.status union widened 14 → 16 values (M2 addition). */
export type M2ContractStatusExtension = 'in_approval' | 'cancelled';

/** Full M2 Contract.status union — M1a 14 values + M2 2 additions. */
export type M2ContractStatus = M1aContractStatus | M2ContractStatusExtension;

/** AE-1 — ContractActivity.activityType widened 9 → 14 values. */
export type M2ActivityTypeExtension =
  | 'submitted_for_approval'
  | 'approval_decided'
  | 'approval_reassigned'
  | 'approval_escalated'
  | 'approval_delegated';

/** Full M2 ContractActivity.activityType union — 14 values. */
export type M2ActivityType = M1aActivityType | M2ActivityTypeExtension;

export const M2_ACTIVITY_TYPE_EXTENSIONS = [
  'submitted_for_approval',
  'approval_decided',
  'approval_reassigned',
  'approval_escalated',
  'approval_delegated',
] as const;

// ------------------------------------------------------------
// 2. M2 enum unions
// ------------------------------------------------------------

export type ApprovalChainStatus =
  | 'in_progress'
  | 'approved'
  | 'rejected'
  | 'resubmission_requested'
  | 'cancelled';

export type ApprovalStepStatus =
  | 'pending'
  | 'approved'
  | 'rejected'
  | 'resubmission_requested'
  | 'escalated'
  | 'reassigned'
  | 'delegated'
  | 'skipped';

export type ApprovalDecisionType =
  | 'approve'
  | 'reject'
  | 'request_resubmission'
  | 'delegate'
  | 'reassign'
  | 'escalate';

export type ApprovalPendingSort = 'oldest' | 'newest' | 'highest_value';

// ------------------------------------------------------------
// 3. approval_matrix
// ------------------------------------------------------------

export interface ApprovalMatrix {
  id: number;
  contractType: string;
  valueMin: number;
  valueMax: number | null;
  stepOrder: number;
  parallelGroup: number | null;
  approverRole: string;
  isRequired: boolean;
  escalationRole: string | null;
  escalationAfterHours: number | null;
  createdAt: string;
  updatedAt: string;
}

export interface ApprovalMatrixRuleInput {
  stepOrder: number;
  parallelGroup?: number;
  approverRole: string;
  isRequired?: boolean;
  escalationRole?: string;
  escalationAfterHours?: number;
}

export interface UpdateApprovalMatrixDto {
  contractType: string;
  valueMin: number;
  valueMax?: number | null;
  rules: ApprovalMatrixRuleInput[];
}

export type CreateApprovalMatrixDto = UpdateApprovalMatrixDto;

export interface ApprovalMatrixListQuery {
  page?: number;
  limit?: number;
  contractType?: string;
}

export type ApprovalMatrixListResponse = Paginated<ApprovalMatrix>;

export interface ApprovalMatrixSetResponse {
  contractType: string;
  minValueAed: number;
  maxValueAed: number | null;
  ruleCount: number;
  ruleIds: number[];
}

// ------------------------------------------------------------
// 4. approval_chain
// ------------------------------------------------------------

export interface ApprovalMatrixSnapshotEntry {
  stepOrder: number;
  parallelGroup: number | null;
  approverRole: string;
  isRequired: boolean;
  escalationRole: string | null;
  escalationAfterHours: number | null;
}

export interface ApprovalChainStepDecisionItem {
  id: number;
  decision: ApprovalDecisionType;
  decisionNote: string | null;
  decidedBy: UserRef;
  decidedAt: string;
}

export interface ApprovalChainStepDetail {
  id: number;
  stepOrder: number;
  parallelGroup: number | null;
  approverRole: string;
  approverUser: UserRef | null;
  status: ApprovalStepStatus;
  isRequired: boolean;
  escalationRole: string | null;
  escalationAfterHours: number | null;
  reassignedTo: UserRef | null;
  delegatedTo: UserRef | null;
  decisions: ApprovalChainStepDecisionItem[];
}

export interface ApprovalChainGetResponseChain {
  id: number;
  contractId: number;
  status: ApprovalChainStatus;
  currentStepOrder: number;
  submittedBy: UserRef;
  submittedAt: string;
  completedAt: string | null;
}

export interface ApprovalChainDetail {
  chain: ApprovalChainGetResponseChain;
  steps: ApprovalChainStepDetail[];
}

export type ApprovalChainGetResponse = ApprovalChainDetail;

export interface ApprovalChainListItem {
  id: number;
  contractId: number;
  contractNumber: string;
  status: ApprovalChainStatus;
  currentStepOrder: number;
  totalSteps: number;
  submittedBy: UserRef;
  submittedAt: string;
  completedAt: string | null;
  hoursPending: number;
}

export interface ApprovalChainListQuery {
  page?: number;
  limit?: number;
  contractId?: number;
  status?: ApprovalChainStatus;
  submittedBy?: number;
}

export type ApprovalChainListResponse = Paginated<ApprovalChainListItem>;

// ------------------------------------------------------------
// 5. fn_approval_route_init / preview shapes (S6 + S7)
// ------------------------------------------------------------

export interface RouteInitPreviewStep {
  stepOrder: number;
  parallelGroup: number | null;
  approverRole: string;
  isRequired: boolean;
  escalationRole: string | null;
  escalationAfterHours: number | null;
}

export interface RouteInitPreviewRequest {
  contractType: string;
  valueAed: number;
}

export interface RouteInitPreviewResponse {
  contractType: string;
  valueAed: number;
  steps: RouteInitPreviewStep[];
  hasNoMatchingRule: boolean;
}

export type SubmitForApprovalRequest = Record<string, never>;

export interface SubmitForApprovalResponse {
  chainId: number;
  contractId: number;
  totalSteps: number;
  currentStepOrder: number;
  newContractStatus: 'in_approval';
}

// ------------------------------------------------------------
// 6. fn_approval_my_pending shapes (S1)
// ------------------------------------------------------------

export interface MyPendingApprovalListItem {
  stepId: number;
  chainId: number;
  contractId: number;
  contractNumber: string;
  contractTitleEn: string;
  contractTitleAr: string | null;
  valueAed: number | null;
  requesterUserRef: UserRef | null;
  stepOrder: number;
  parallelGroup: number | null;
  isRequired: boolean;
  hoursPending: number;
  escalationRole: string | null;
  escalationAfterHours: number | null;
}

export interface MyPendingApprovalListQuery {
  page?: number;
  limit?: number;
  sort?: ApprovalPendingSort;
}

export type MyPendingApprovalListResponse = Paginated<MyPendingApprovalListItem>;

// ------------------------------------------------------------
// 7. Decision / delegate / reassign DTOs (S2 / S3 / S8)
// ------------------------------------------------------------

export interface DecideApprovalDto {
  decision: 'approve' | 'reject' | 'request_resubmission';
  decisionNote?: string;
}

export interface DecideApprovalResponse {
  stepId: number;
  chainId: number;
  contractId: number;
  newStepStatus: ApprovalStepStatus;
  newChainStatus: ApprovalChainStatus;
  newContractStatus: M2ContractStatus;
  advancedToStepOrder: number | null;
  allChainStepsResolved: boolean;
}

export interface DelegateApprovalDto {
  delegatedToUserId: number;
  decisionNote?: string;
}

export interface DelegateApprovalResponse {
  stepId: number;
  delegatedTo: UserRef;
  decisionId: number;
}

export interface ReassignApprovalDto {
  reassignedToUserId: number;
  decisionNote?: string;
}

export interface ReassignApprovalResponse {
  stepId: number;
  originalApprover: UserRef | null;
  reassignedTo: UserRef;
  decisionId: number;
}

// ------------------------------------------------------------
// 8. UpdateContractStatusUserDto (M2 / AE-2)
// ------------------------------------------------------------

export interface UpdateContractStatusUserDto {
  newStatus: M2ContractStatus;
  reason?: string | null;
}

export interface UpdateContractStatusUserResponse {
  id: number;
  fromStatus: M2ContractStatus;
  toStatus: M2ContractStatus;
  changedAt: string;
  /** Present when transition was in_review → in_approval (chain init). */
  routeInit?: SubmitForApprovalResponse | null;
}

// ------------------------------------------------------------
// 9. fn_approval_escalate response (cron-driver consumption only)
// ------------------------------------------------------------

export interface ApprovalEscalateResponse {
  stepId: number;
  escalationRole: string | null;
  escalatedToUserId: number | null;
  newPeerStepId: number | null;
  decisionId: number | null;
}

// ------------------------------------------------------------
// 10. Permission codes + sensitive field constants
// ------------------------------------------------------------

export const M2_NEW_PERMISSIONS = [
  'approval.submit_for_review',
  'approval.act',
  'approval.delegate',
  'approval.matrix.read',
  'approval.matrix.write',
  'approval.reassign',
] as const;

export type M2PermissionCode = (typeof M2_NEW_PERMISSIONS)[number];

export const M2_SENSITIVE_FIELD_EXTENSIONS = [
  'decision_note',
  'matrix_snapshot',
] as const;

export type M2SensitiveFieldName = (typeof M2_SENSITIVE_FIELD_EXTENSIONS)[number];
