/**
 * M19 / CR-K — Zod validation schemas for /api/v1/risk-cases endpoints.
 *
 * Every shape mirrors api-contracts.json for Unit 7 exactly. All write
 * schemas use .strict() per DD-1. Coercion is applied to query-string
 * params (numbers + booleans) because Express delivers them as strings.
 */
import { z } from 'zod';

// ----------------------------------------------------------------
// Shared enums
// ----------------------------------------------------------------

export const riskCasePriorityEnum = z.enum(['low', 'medium', 'high', 'critical']);

export const riskCaseTransitionStatusEnum = z.enum(['in_review', 'approved', 'rejected']);

export const riskCaseStatusEnum = z.enum([
  'open',
  'in_review',
  'approved',
  'rejected',
  'escalated',
  'accept_risk',
  'snoozed',
  'closed',
  'open_all',
]);

export const riskCaseTypeEnum = z.enum([
  'correlation_alert',
  'obligation_due',
  'sla_breach',
  'system',
  'manual',
]);

export const riskCaseClosureOutcomeEnum = z.enum([
  'mitigated',
  'accepted',
  'no_action',
  'advisory_dispatched',
]);

// ----------------------------------------------------------------
// list / query
// ----------------------------------------------------------------

export const listRiskCasesSchema = z.object({
  status: riskCaseStatusEnum.optional(),
  priority: riskCasePriorityEnum.optional(),
  assignedToMe: z
    .string()
    .optional()
    .transform((v) => v === 'true'),
  slaDueWithinHours: z.coerce.number().int().min(1).max(720).optional(),
  caseType: riskCaseTypeEnum.exclude(['system']).optional().or(riskCaseTypeEnum.optional()),
  search: z.string().trim().max(200).optional(),
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().positive().max(100).default(20),
});

// ----------------------------------------------------------------
// create
// ----------------------------------------------------------------

export const createRiskCaseSchema = z
  .object({
    contractId: z.number().int().positive().nullable().optional(),
    priority: riskCasePriorityEnum,
    title: z.string().trim().min(1, 'title is required').max(500),
    body: z.string().trim().min(1).nullable().optional(),
    assignedRole: z.string().trim().min(1).nullable().optional(),
    assignedUserId: z.number().int().positive().nullable().optional(),
    slaHours: z.number().int().positive().nullable().optional(),
    metadata: z.record(z.unknown()).optional(),
  })
  .strict();

// ----------------------------------------------------------------
// assign
// ----------------------------------------------------------------

export const assignRiskCaseSchema = z
  .object({
    assignedRole: z.string().trim().min(1).nullable().optional(),
    assignedUserId: z.number().int().positive().nullable().optional(),
  })
  .strict()
  .refine(
    (data) =>
      (data.assignedRole !== undefined && data.assignedRole !== null) ||
      (data.assignedUserId !== undefined && data.assignedUserId !== null),
    {
      message: 'Either assignedRole or assignedUserId is required',
    },
  );

// ----------------------------------------------------------------
// comments + evidence
// ----------------------------------------------------------------

export const addRiskCaseCommentSchema = z
  .object({
    comment: z.string().trim().min(1, 'comment is required').max(5000),
  })
  .strict();

/**
 * DEFECT-CRKL-INTV-1 (2026-05-15) — Evidence upload is multipart/form-data.
 *
 * The FE posts a FormData with:
 *   - `file`     : binary (handled by multer.single('file'); becomes req.file)
 *   - `fileName` : text — original filename (FE-provided; controller defaults
 *                  to req.file.originalname if missing/blank).
 *   - `fileMime` : text — MIME from the browser (FE-provided; defence-in-depth
 *                  cross-checked against req.file.mimetype in the controller).
 *   - `fileBytes`: text — FE-supplied length as a string (FormData has no
 *                  number type). Validated to be >0 and <=50MB. Cross-checked
 *                  against req.file.size in the controller.
 *
 * `fileUri` is **server-derived** from the Supabase Storage upload — never
 * accepted from the client. Therefore the wire schema does NOT include it.
 * The fn signature still binds `(actor, id, fileUri, fileName, fileMime,
 * fileBytes)`; the controller passes the derived storagePath as fileUri.
 *
 * The legacy `addRiskCaseEvidenceSchema` (JSON shape with fileUri) is
 * retained but is **no longer mounted on the route** — kept only for type
 * documentation of the fn-argument shape, plus for the (zero) downstream
 * tests that may still import it.
 */
export const addRiskCaseEvidenceMultipartFieldsSchema = z
  .object({
    fileName: z
      .string()
      .trim()
      .min(1, 'fileName is required')
      .max(255)
      .optional(),
    fileMime: z
      .string()
      .trim()
      .min(1, 'fileMime is required')
      .max(100)
      .optional(),
    fileBytes: z
      .union([
        z.number().int().positive(),
        z
          .string()
          .trim()
          .regex(/^\d+$/, 'fileBytes must be an integer string')
          .transform((s) => parseInt(s, 10))
          .refine((n) => n > 0, 'fileBytes must be > 0'),
      ])
      .refine((n) => n <= 52428800, 'fileBytes must be <= 50MB')
      .optional(),
    kind: z.string().trim().min(1).max(50).optional(),
    description: z.string().trim().max(1000).optional(),
  })
  // Note: NOT .strict() — multer attaches additional metadata + form-mode
  // browsers occasionally send extra empty fields; we tolerate unknowns.
  .passthrough();

/**
 * @deprecated DEFECT-CRKL-INTV-1 — kept for the fn-argument shape; the wire
 * shape moved to addRiskCaseEvidenceMultipartFieldsSchema. Do NOT mount on
 * the route.
 */
export const addRiskCaseEvidenceSchema = z
  .object({
    fileUri: z.string().trim().min(1, 'fileUri is required'),
    fileName: z.string().trim().min(1, 'fileName is required').max(255),
    fileMime: z.string().trim().min(1, 'fileMime is required').max(100),
    fileBytes: z
      .number()
      .int()
      .positive()
      .max(52428800, 'fileBytes must be <= 50MB'),
  })
  .strict();

// ----------------------------------------------------------------
// lifecycle write actions
// ----------------------------------------------------------------

export const statusTransitionRiskCaseSchema = z
  .object({
    toStatus: riskCaseTransitionStatusEnum,
    decisionNote: z.string().trim().min(1).max(5000).nullable().optional(),
  })
  .strict();

export const escalateRiskCaseSchema = z
  .object({
    reason: z.string().trim().min(1).max(5000).nullable().optional(),
  })
  .strict();

export const acceptRiskCaseSchema = z
  .object({
    approverUserId: z.number().int().positive(),
    justification: z
      .string()
      .trim()
      .min(10, 'justification must be at least 10 characters')
      .max(10000),
  })
  .strict();

export const snoozeRiskCaseSchema = z
  .object({
    snoozedUntil: z
      .string()
      .datetime({ message: 'snoozedUntil must be an ISO 8601 datetime' }),
  })
  .strict();

export const closeRiskCaseSchema = z
  .object({
    outcome: riskCaseClosureOutcomeEnum,
    closureNote: z.string().trim().min(1).max(5000).nullable().optional(),
  })
  .strict();

// ----------------------------------------------------------------
// auto-create (internal, system-only)
// ----------------------------------------------------------------

export const autoCreateRiskCaseSchema = z
  .object({
    correlationId: z.number().int().positive(),
  })
  .strict();

// ----------------------------------------------------------------
// escalation-check (internal, system-only)
// ----------------------------------------------------------------

export const riskCaseEscalationCheckQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(1000).default(100),
});

// ----------------------------------------------------------------
// Inferred types (exported for controller use)
// ----------------------------------------------------------------

export type ListRiskCasesInput = z.infer<typeof listRiskCasesSchema>;
export type CreateRiskCaseInput = z.infer<typeof createRiskCaseSchema>;
export type AssignRiskCaseInput = z.infer<typeof assignRiskCaseSchema>;
export type AddRiskCaseCommentInput = z.infer<typeof addRiskCaseCommentSchema>;
export type AddRiskCaseEvidenceInput = z.infer<typeof addRiskCaseEvidenceSchema>;
export type AddRiskCaseEvidenceMultipartFieldsInput = z.infer<
  typeof addRiskCaseEvidenceMultipartFieldsSchema
>;
export type StatusTransitionRiskCaseInput = z.infer<typeof statusTransitionRiskCaseSchema>;
export type EscalateRiskCaseInput = z.infer<typeof escalateRiskCaseSchema>;
export type AcceptRiskCaseInput = z.infer<typeof acceptRiskCaseSchema>;
export type SnoozeRiskCaseInput = z.infer<typeof snoozeRiskCaseSchema>;
export type CloseRiskCaseInput = z.infer<typeof closeRiskCaseSchema>;
export type AutoCreateRiskCaseInput = z.infer<typeof autoCreateRiskCaseSchema>;
