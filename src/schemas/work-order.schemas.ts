import { z } from 'zod';

/**
 * Work Order Queue (M21) — Zod wire schemas.
 *
 * Endpoints:
 *   GET    /api/v1/work-orders                  → listMine
 *   GET    /api/v1/work-orders/assignable-drafters → assignableDrafters (exec dropdown)
 *   GET    /api/v1/work-orders/:id              → getById
 *   POST   /api/v1/work-orders/from-contract    → createDraftFromContract (exec)
 *   POST   /api/v1/work-orders/:id/complete     → complete
 *   POST   /api/v1/work-orders/:id/cancel       → cancel
 */

export const WORK_ORDER_TYPES = [
  'contract_draft_request',
  'contract_returned',
  'comment_response',
] as const;

export const WORK_ORDER_STATUSES = [
  'open',
  'in_progress',
  'completed',
  'cancelled',
] as const;

export const listMineQuerySchema = z.object({
  status: z
    .string()
    .optional()
    .transform((v) => (v ? v.split(',').filter(Boolean) : undefined))
    .pipe(z.array(z.enum(WORK_ORDER_STATUSES)).optional()),
  type: z
    .string()
    .optional()
    .transform((v) => (v ? v.split(',').filter(Boolean) : undefined))
    .pipe(z.array(z.enum(WORK_ORDER_TYPES)).optional()),
  limit: z.coerce.number().int().positive().max(500).default(100),
  // M21 mig 632 — pagination. Default page=1 keeps every existing caller's
  // behaviour identical.
  page: z.coerce.number().int().positive().default(1),
});

export const createDraftRequestSchema = z.object({
  sourceContractId: z.coerce.number().int().positive(),
  assignedDrafterId: z.coerce.number().int().positive(),
  // Exec picks ONE: existing party id OR free-text prospect name. Validation
  // below ensures at least one is set when both are provided we prefer the id.
  counterpartyId: z.coerce.number().int().positive().nullish(),
  counterpartyProspectName: z.string().trim().min(1).max(200).nullish(),
  instructionNote: z.string().trim().max(2000).nullish(),
  valueAed: z.coerce.number().nonnegative().nullish(),
  priority: z.enum(['low', 'normal', 'high', 'urgent']).default('normal'),
  dueAt: z.string().datetime().nullish(),
});

// Back-compat alias so any code path still importing the old name compiles.
export const createDraftFromContractSchema = createDraftRequestSchema;

export const extractFromSourceSchema = z.object({
  sourceContractId: z.coerce.number().int().positive(),
});

export const linkTargetSchema = z.object({
  contractId: z.coerce.number().int().positive(),
});

export const cancelWorkOrderSchema = z.object({
  reason: z.string().trim().max(500).nullish(),
});

// M21 2026-06-12 v2 — manual "Add to my queue" with the user-requested 4-field
// shape: requestType, instructionNote, requestorUserId, initialStage.
// Drafter is self-assigned by the BE controller; requestor is the person who
// asked for the work (stored as assigned_by_user_id by fn_work_order_create_manual).
export const MANUAL_INITIAL_STAGES = [
  'not_started',
  'in_progress',
  'completed',
] as const;

export const createManualWorkOrderSchema = z.object({
  requestType: z.enum(WORK_ORDER_TYPES),
  instructionNote: z.string().trim().min(1).max(2000),
  requestorUserId: z.coerce.number().int().positive(),
  initialStage: z.enum(MANUAL_INITIAL_STAGES).default('not_started'),
  // 2026-06-12 mig 631 — optional similar-contract id when requestType =
  // contract_draft_request. The fn re-verifies tenant scoping via RLS.
  sourceContractId: z.coerce.number().int().positive().nullish(),
});

export type CreateManualWorkOrderBody = z.infer<typeof createManualWorkOrderSchema>;

// 2026-06-12 mig 631 — Effective stage values for the drafter's manual override.
// Five values rather than six because work_order.status already encodes
// 'cancelled' independently — overriding to 'cancelled' would be a separate flow.
export const MANUAL_STAGE_VALUES = [
  'not_started',
  'draft_in_progress',
  'awaiting_approval',
  'returned',
  'completed',
] as const;

export const setStageSchema = z.object({
  stage: z.enum(MANUAL_STAGE_VALUES).nullable(),
});

export const lookupContractQuerySchema = z.object({
  number: z.string().trim().min(1).max(100),
});

// M21 mig 638 — exec "Assigned Work" listing. Same shape as listMineQuery
// plus an optional ownerId narrow.
export const listAssignedByMeQuerySchema = z.object({
  status: z
    .string()
    .optional()
    .transform((v) => (v ? v.split(',').filter(Boolean) : undefined))
    .pipe(z.array(z.enum(WORK_ORDER_STATUSES)).optional()),
  type: z
    .string()
    .optional()
    .transform((v) => (v ? v.split(',').filter(Boolean) : undefined))
    .pipe(z.array(z.enum(WORK_ORDER_TYPES)).optional()),
  ownerId: z.coerce.number().int().positive().optional(),
  limit: z.coerce.number().int().positive().max(500).default(20),
  page: z.coerce.number().int().positive().default(1),
});

// M21 mig 639 — nudge body.
export const nudgeWorkOrderSchema = z.object({
  message: z.string().trim().max(500).nullish(),
});

// M21 mig 639 — reassign body.
export const reassignWorkOrderSchema = z.object({
  newAssigneeId: z.coerce.number().int().positive(),
  reason: z.string().trim().max(500).nullish(),
});

export type SetStageBody = z.infer<typeof setStageSchema>;
export type LookupContractQuery = z.infer<typeof lookupContractQuerySchema>;
export type ListAssignedByMeQuery = z.infer<typeof listAssignedByMeQuerySchema>;
export type NudgeWorkOrderBody = z.infer<typeof nudgeWorkOrderSchema>;
export type ReassignWorkOrderBody = z.infer<typeof reassignWorkOrderSchema>;

export type ListMineQuery = z.infer<typeof listMineQuerySchema>;
export type CreateDraftRequestBody = z.infer<typeof createDraftRequestSchema>;
export type CreateDraftFromContractBody = CreateDraftRequestBody;
export type CancelWorkOrderBody = z.infer<typeof cancelWorkOrderSchema>;
export type ExtractFromSourceBody = z.infer<typeof extractFromSourceSchema>;
export type LinkTargetBody = z.infer<typeof linkTargetSchema>;
