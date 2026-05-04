// ============================================================
// M2 — Approval Workflows — Zod schemas
// ============================================================
// One schema per fn_ entry point. Field error messages mirror the AC
// contracts in requirements-analysis.json so test "expected message"
// assertions line up.
//
// S2-16 alignment: every Zod schema's keys MUST match the keys the fn_
// reads (camelCase wire shape). Spot-checked against db-design.md §2-§3
// fn_approval_*  parameter lists.
// ============================================================
import { z } from 'zod';
import { PositiveBigIntSchema } from './contracts.schemas';

// ------------------------------------------------------------
// 1. Reusable enums
// ------------------------------------------------------------

/** approval_chain.status — 5-value lifecycle CHECK enum. */
export const ApprovalChainStatusSchema = z.enum(
  ['in_progress', 'approved', 'rejected', 'resubmission_requested', 'cancelled'],
  { errorMap: () => ({ message: 'Invalid status value' }) },
);

/** Sort options for fn_approval_my_pending. */
export const ApprovalPendingSortSchema = z.enum(['oldest', 'newest', 'highest_value'], {
  errorMap: () => ({ message: 'sort must be one of oldest|newest|highest_value' }),
});

// ------------------------------------------------------------
// 2. Path params
// ------------------------------------------------------------

/** :stepId path param. */
export const ApprovalStepIdParamSchema = z.object({
  stepId: PositiveBigIntSchema,
});
export type ApprovalStepIdParamInferred = z.infer<typeof ApprovalStepIdParamSchema>;

// ------------------------------------------------------------
// 3. Query params
// ------------------------------------------------------------

/** GET /api/v1/approvals/my-pending. */
export const MyPendingApprovalListQuerySchema = z.object({
  page: z.coerce.number().int().min(1, 'Page must be >= 1').optional().default(1),
  limit: z.coerce
    .number()
    .int()
    .min(1, 'Limit must be between 1 and 100')
    .max(100, 'Limit must be between 1 and 100')
    .optional()
    .default(20),
  sort: ApprovalPendingSortSchema.optional().default('oldest'),
});
export type MyPendingApprovalListQueryInferred = z.infer<
  typeof MyPendingApprovalListQuerySchema
>;

/** GET /api/v1/admin/approval-matrix. */
export const ApprovalMatrixListQuerySchema = z.object({
  page: z.coerce.number().int().min(1, 'Page must be >= 1').optional().default(1),
  limit: z.coerce
    .number()
    .int()
    .min(1, 'Limit must be between 1 and 100')
    .max(100, 'Limit must be between 1 and 100')
    .optional()
    .default(50),
  contractType: z.string().trim().min(1).max(50).optional(),
});
export type ApprovalMatrixListQueryInferred = z.infer<typeof ApprovalMatrixListQuerySchema>;

/** GET /api/v1/admin/approval-chains. */
export const ApprovalChainListQuerySchema = z.object({
  page: z.coerce.number().int().min(1, 'Page must be >= 1').optional().default(1),
  limit: z.coerce
    .number()
    .int()
    .min(1, 'Limit must be between 1 and 100')
    .max(100, 'Limit must be between 1 and 100')
    .optional()
    .default(20),
  contractId: PositiveBigIntSchema.optional(),
  status: ApprovalChainStatusSchema.optional(),
  submittedBy: PositiveBigIntSchema.optional(),
});
export type ApprovalChainListQueryInferred = z.infer<typeof ApprovalChainListQuerySchema>;

// ------------------------------------------------------------
// 4. fn_approval_decide DTO (S2)
// ------------------------------------------------------------

/**
 * Subset of ApprovalDecisionType valid for /decide. delegate / reassign /
 * escalate are SEPARATE endpoints; fn_approval_decide rejects them at
 * step 1 → 400 'decision:Invalid decision'.
 */
export const DecideApprovalSchema = z
  .object({
    decision: z.enum(['approve', 'reject', 'request_resubmission'], {
      errorMap: () => ({ message: 'Invalid decision' }),
    }),
    decisionNote: z.string().trim().max(4000).optional(),
  })
  .superRefine((val, ctx) => {
    // AC-S2-02 / AC-S2-03 — decisionNote required when decision in {reject, request_resubmission}
    if (val.decision === 'reject' || val.decision === 'request_resubmission') {
      const note = val.decisionNote;
      if (note === undefined || note === null || note.length === 0) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['decisionNote'],
          message: `decisionNote is required for ${val.decision}`,
        });
      }
    }
  });
export type DecideApprovalInferred = z.infer<typeof DecideApprovalSchema>;

// ------------------------------------------------------------
// 5. fn_approval_delegate DTO (S3)
// ------------------------------------------------------------

export const DelegateApprovalSchema = z.object({
  delegatedToUserId: PositiveBigIntSchema,
  decisionNote: z.string().trim().max(4000).optional(),
});
export type DelegateApprovalInferred = z.infer<typeof DelegateApprovalSchema>;

// ------------------------------------------------------------
// 6. fn_approval_reassign DTO (S8)
// ------------------------------------------------------------

export const ReassignApprovalSchema = z.object({
  reassignedToUserId: PositiveBigIntSchema,
  decisionNote: z.string().trim().max(4000).optional(),
});
export type ReassignApprovalInferred = z.infer<typeof ReassignApprovalSchema>;

// ------------------------------------------------------------
// 7. fn_approval_matrix_set DTO (S5)
// ------------------------------------------------------------

const ApprovalMatrixRuleSchema = z
  .object({
    stepOrder: z
      .number({ invalid_type_error: 'stepOrder must be a positive integer' })
      .int()
      .positive('stepOrder must be a positive integer'),
    parallelGroup: z
      .number({ invalid_type_error: 'parallelGroup must be a positive integer' })
      .int()
      .positive('parallelGroup must be a positive integer')
      .optional(),
    approverRole: z
      .string({ required_error: 'approverRole is required' })
      .trim()
      .min(1, 'approverRole is required')
      .max(64, 'approverRole must be at most 64 characters'),
    isRequired: z.boolean().optional(),
    escalationRole: z.string().trim().min(1).max(64).optional(),
    escalationAfterHours: z
      .number({ invalid_type_error: 'escalationAfterHours must be > 0' })
      .int()
      .positive('escalationAfterHours must be > 0')
      .optional(),
  })
  .superRefine((val, ctx) => {
    // AC-S5-05: parallelGroup, when set, MUST equal stepOrder.
    if (val.parallelGroup !== undefined && val.parallelGroup !== val.stepOrder) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['parallelGroup'],
        message: 'parallelGroup must equal stepOrder',
      });
    }
  });

export const UpdateApprovalMatrixSchema = z
  .object({
    contractType: z
      .string({ required_error: 'contractType is required' })
      .trim()
      .min(1, 'contractType is required')
      .max(50, 'Invalid contractType'),
    valueMin: z
      .number({ invalid_type_error: 'valueMin must be >= 0' })
      .nonnegative('valueMin must be >= 0'),
    valueMax: z
      .number({ invalid_type_error: 'valueMax must be a number' })
      .nonnegative('valueMax must be >= 0')
      .nullable()
      .optional(),
    rules: z
      .array(ApprovalMatrixRuleSchema)
      .min(1, 'rules array must not be empty'),
  })
  .superRefine((val, ctx) => {
    // AC-S5-04 — non-empty already enforced by .min(1).
    // AC-S5-02 — stepOrder values 1..N continuous (defense-in-depth; fn_ raises 22023).
    const orders = val.rules.map((r) => r.stepOrder).sort((a, b) => a - b);
    for (let i = 0; i < orders.length; i++) {
      if (orders[i] !== i + 1) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['rules'],
          message: 'step_order has gaps; expected sequence 1..N',
        });
        break;
      }
    }
    // valueMax >= valueMin (when set)
    if (val.valueMax !== undefined && val.valueMax !== null && val.valueMax < val.valueMin) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['valueMax'],
        message: 'valueMax must be >= valueMin',
      });
    }
  });
export type UpdateApprovalMatrixInferred = z.infer<typeof UpdateApprovalMatrixSchema>;

// ------------------------------------------------------------
// 8. fn_approval_route_init_preview DTO (S6)
// ------------------------------------------------------------

export const RouteInitPreviewSchema = z.object({
  contractType: z
    .string({ required_error: 'contractType is required' })
    .trim()
    .min(1, 'contractType is required')
    .max(50, 'Invalid contractType'),
  valueAed: z
    .number({ invalid_type_error: 'valueAed must be >= 0' })
    .nonnegative('valueAed must be >= 0'),
});
export type RouteInitPreviewInferred = z.infer<typeof RouteInitPreviewSchema>;

// ------------------------------------------------------------
// 9. fn_approval_route_init DTO (S7) — empty body
// ------------------------------------------------------------

/**
 * Empty body. fn_approval_route_init reads only p_contract_id (path)
 * + p_actor_id (JWT). z.object({}) is forward-extensible — swap to
 * z.object({}).strict() if a future extension needs strict body validation.
 */
export const SubmitForApprovalSchema = z.object({}).strict();
export type SubmitForApprovalInferred = z.infer<typeof SubmitForApprovalSchema>;
