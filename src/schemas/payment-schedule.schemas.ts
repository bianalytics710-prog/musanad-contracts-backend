// ============================================================
// M1b — Contracts: Compose Wizard, Payment Schedules & Exports
// Zod Schemas (BE)
//
// Project:   Musanad Contracts Hub (musanad-contracts)
// Module:    M1b
// Source:    .claude/workspace/current-module/schemas.ts (Agent 5)
// Derived:   db-design.md v1.0 (Agent 4)
//            requirements-analysis.json (Agent 2)
//
// Each schema mirrors the AC error contracts in requirements-analysis.json —
// when a Zod parse fails, the error path's leaf segment is the same `field`
// name the corresponding AC requires.
// ============================================================

import { z } from 'zod';
import {
  // M1a primitives we REUSE (do NOT redeclare)
  PositiveBigIntSchema,
  IsoDateSchema,
  ContractStatusSchema,
  ContractLanguageSchema,
  GoverningLawSchema,
  RelationshipTypeSchema,
  ContractIdParamSchema,
  ContractListQuerySchema,
} from './contracts.schemas';

// Re-export so M1b consumers (BE controllers, tests) can import everything
// from one barrel. Same pattern as M1a → M0 re-exports.
export {
  PositiveBigIntSchema,
  IsoDateSchema,
  ContractStatusSchema,
  ContractLanguageSchema,
  GoverningLawSchema,
  RelationshipTypeSchema,
  ContractIdParamSchema,
  ContractListQuerySchema,
};

// ------------------------------------------------------------
// 1. Local primitives (M1b-specific)
// ------------------------------------------------------------

const NonEmptyString = (msg: string, max?: number): z.ZodString => {
  let s = z.string({ required_error: msg, invalid_type_error: msg }).trim().min(1, msg);
  if (max !== undefined) s = s.max(max, msg);
  return s;
};

const NonNegativeAmount = z
  .number({
    required_error: 'Amount must be greater than or equal to zero',
    invalid_type_error: 'Amount must be greater than or equal to zero',
  })
  .nonnegative('Amount must be greater than or equal to zero');

// ------------------------------------------------------------
// 2. Enum schemas — M1b-owned
// ------------------------------------------------------------

export const PaymentScheduleStatusSchema = z.enum(
  ['pending', 'due', 'paid', 'overdue', 'waived', 'cancelled'],
  { errorMap: () => ({ message: 'Invalid status value' }) },
);
export type PaymentScheduleStatusInferred = z.infer<typeof PaymentScheduleStatusSchema>;

export const PaymentScheduleRecurrenceSchema = z.enum(
  ['once', 'monthly', 'quarterly', 'annually'],
  { errorMap: () => ({ message: 'Invalid recurrence value' }) },
);
export type PaymentScheduleRecurrenceInferred = z.infer<typeof PaymentScheduleRecurrenceSchema>;

// ------------------------------------------------------------
// 3. PaymentScheduleCreateDto — single row inside the bulk payload
// ------------------------------------------------------------

export const PaymentScheduleCreateSchema = z.object({
  milestoneLabelEn: NonEmptyString('Milestone label is required', 255), // AC-S3-05
  milestoneLabelAr: z.string().trim().max(255).nullable().optional(),
  milestoneNameEn: z.string().trim().max(500).nullable().optional(),
  milestoneNameAr: z.string().trim().max(500).nullable().optional(),
  amountAed: NonNegativeAmount, // AC-S3-06
  dueDate: IsoDateSchema.nullable().optional(),
  paidAt: IsoDateSchema.nullable().optional(),
  status: PaymentScheduleStatusSchema.optional(), // AC-S3-07
  recurrence: PaymentScheduleRecurrenceSchema.nullable().optional(), // AC-S3-08
  invoiceRef: z.string().trim().max(100).nullable().optional(),
});
export type PaymentScheduleCreateInferred = z.infer<typeof PaymentScheduleCreateSchema>;

// ------------------------------------------------------------
// 4. PaymentScheduleBulkReplaceDto — request body for PUT
// ------------------------------------------------------------

export const PaymentScheduleBulkReplaceSchema = z
  .object({
    rows: z
      .array(PaymentScheduleCreateSchema, {
        required_error: 'rows must be a non-empty array',
        invalid_type_error: 'rows must be a non-empty array',
      })
      .min(1, 'rows must be a non-empty array') // AC-S3-04
      .max(100, 'Maximum 100 milestones per batch'), // AC-S3-09
    replaceExisting: z.boolean().optional(),
  })
  .superRefine((val, ctx) => {
    // Duplicate-label client-side guard.
    const seen = new Map<string, number>();
    val.rows.forEach((r, i) => {
      const key = r.milestoneLabelEn.trim().toLowerCase();
      if (seen.has(key)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['rows', i, 'milestoneLabelEn'],
          message: 'Duplicate milestone label within batch',
        });
      } else {
        seen.set(key, i);
      }
    });

    // chk_payment_schedule_paid_at_status mirror.
    val.rows.forEach((r, i) => {
      const hasPaidAt = typeof r.paidAt === 'string' && r.paidAt.length > 0;
      if (hasPaidAt && r.status !== undefined && r.status !== 'paid') {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['rows', i, 'paidAt'],
          message: 'paidAt is only permitted when status is paid',
        });
      }
    });
  });
export type PaymentScheduleBulkReplaceInferred = z.infer<typeof PaymentScheduleBulkReplaceSchema>;

/** Alias matching api-contracts.json naming. */
export const ReplacePaymentScheduleDtoSchema = PaymentScheduleBulkReplaceSchema;

// ------------------------------------------------------------
// 5. PaymentScheduleListQuerySchema — GET /:id/payment-schedules
// ------------------------------------------------------------

export const PaymentScheduleListQuerySchema = z.object({
  status: PaymentScheduleStatusSchema.optional(), // AC-S2-06
});
export type PaymentScheduleListQueryInferred = z.infer<typeof PaymentScheduleListQuerySchema>;

// ------------------------------------------------------------
// 6. ContractExportPdfQuerySchema — GET /:id/export.pdf (S4)
// ------------------------------------------------------------

export const ContractExportPdfQuerySchema = z.object({
  language: ContractLanguageSchema.optional().default('bilingual'), // AC-S4-05
  includeAttachments: z
    .union([z.boolean(), z.literal('true'), z.literal('false')])
    .optional()
    .transform((v) => v === true || v === 'true'),
});
export type ContractExportPdfQueryInferred = z.infer<typeof ContractExportPdfQuerySchema>;

// ------------------------------------------------------------
// 7. ContractExportXlsxQuerySchema — GET /contracts/export.xlsx (S5)
// ------------------------------------------------------------

/**
 * Tags can arrive as repeated query params (?tags=a&tags=b) or comma list —
 * mirrors M1a ContractListQuerySchema.tags preprocessor for parity.
 */
const TagsArraySchema = z.preprocess(
  (v) => {
    if (v === undefined || v === null) return undefined;
    if (Array.isArray(v)) return v;
    if (typeof v === 'string') {
      return v.includes(',') ? v.split(',').map((s) => s.trim()) : [v];
    }
    return v;
  },
  z.array(z.string().trim().min(1).max(64)).optional(),
);

export const ContractExportXlsxQuerySchema = z.object({
  status: ContractStatusSchema.optional(),
  contractType: z.string().trim().max(50).optional(),
  counterpartyId: PositiveBigIntSchema.optional(),
  draftedBy: PositiveBigIntSchema.optional(),
  approvedBy: PositiveBigIntSchema.optional(),
  startDateFrom: IsoDateSchema.optional(),
  startDateTo: IsoDateSchema.optional(),
  endDateFrom: IsoDateSchema.optional(),
  endDateTo: IsoDateSchema.optional(),
  tags: TagsArraySchema,
  search: z.string().trim().max(500).optional(),
  /** AC-S5-05/06: clamped 1..50000, default 10000. */
  maxRows: z.coerce
    .number({
      required_error: 'maxRows must be between 1 and 50000',
      invalid_type_error: 'maxRows must be between 1 and 50000',
    })
    .int('maxRows must be between 1 and 50000')
    .min(1, 'maxRows must be between 1 and 50000')
    .max(50000, 'maxRows must be between 1 and 50000')
    .optional()
    .default(10000),
});
export type ContractExportXlsxQueryInferred = z.infer<typeof ContractExportXlsxQuerySchema>;

// ------------------------------------------------------------
// 8. fn_audit_log_record helper input schema (BE-internal)
// ------------------------------------------------------------

export const AuditLogRecordInputSchema = z.object({
  tableName: NonEmptyString('tableName is required', 100),
  recordId: PositiveBigIntSchema.nullable(),
  action: z.enum(['INSERT', 'UPDATE', 'DELETE'], {
    errorMap: () => ({ message: 'Invalid action value' }),
  }),
  newValues: z.record(z.unknown()),
  actorId: PositiveBigIntSchema.nullable().optional(),
});
export type AuditLogRecordInputInferred = z.infer<typeof AuditLogRecordInputSchema>;

// ------------------------------------------------------------
// 9. fn_ INPUT JSONB schemas — used by tests to construct fn_ p_data
// ------------------------------------------------------------

export const FnPaymentScheduleCreateBulkRowSchema = PaymentScheduleCreateSchema;

export const FnContractExportPdfInputSchema = z.object({
  contractId: PositiveBigIntSchema,
  actorId: PositiveBigIntSchema,
  actorRole: z.string().optional(),
  language: ContractLanguageSchema.optional().default('bilingual'),
  includeAttachments: z.boolean().optional().default(false),
});

export const FnContractExportXlsxInputSchema = z.object({
  actorId: PositiveBigIntSchema,
  actorRole: z.string().optional(),
  status: ContractStatusSchema.optional(),
  contractType: z.string().trim().max(50).optional(),
  counterpartyId: PositiveBigIntSchema.optional(),
  draftedBy: PositiveBigIntSchema.optional(),
  approvedBy: PositiveBigIntSchema.optional(),
  startDateFrom: IsoDateSchema.optional(),
  startDateTo: IsoDateSchema.optional(),
  endDateFrom: IsoDateSchema.optional(),
  endDateTo: IsoDateSchema.optional(),
  tags: z.array(z.string()).optional(),
  search: z.string().trim().max(500).optional(),
  maxRows: z.number().int().min(1).max(50000).optional().default(10000),
});
