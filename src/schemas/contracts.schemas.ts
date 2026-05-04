// ============================================================
// M1a — Contracts: Core CRUD & Lifecycle — Zod Schemas
// Project: Musanad Contracts Hub (musanad-contracts)
// Derived from: db-design.md (Agent 4) + requirements-analysis.json (Agent 2)
// Generator:    Agent 5 — Contract Generator (M1a slice)
//
// Each schema mirrors the AC error contracts in requirements-analysis.json
// — when a Zod parse fails, the error path produces the same `field` name
// the corresponding AC requires.
//
// Naming: <TypeName>Schema. Type can be inferred via z.infer<typeof X>.
//
// Do not edit manually — regenerate via Agent 5 if DB design changes.
// ============================================================

import { z } from 'zod';

// ------------------------------------------------------------
// 1. Reusable primitives
// ------------------------------------------------------------

/** Positive integer — used for path :id params and FK fields. */
export const PositiveBigIntSchema = z.coerce.number().int().positive('Must be a positive integer');

/** ISO-8601 date (YYYY-MM-DD). Accepts the wider ISO-8601 datetime too. */
export const IsoDateSchema = z
  .string()
  .refine(
    (v) => /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})?)?$/.test(v),
    { message: 'Must be an ISO-8601 date (YYYY-MM-DD) or datetime' },
  );

/**
 * Required non-empty trimmed string.
 *
 * Uses `required_error` + `invalid_type_error` so Zod emits the AC-mandated
 * message both when the field is missing entirely AND when it's the wrong type.
 * Without these, Zod falls back to its built-in 'Required' / 'Expected string,
 * received undefined' strings (smoke-test F2 regression).
 */
const NonEmptyString = (msg: string, max?: number): z.ZodString => {
  let s = z.string({ required_error: msg, invalid_type_error: msg }).trim().min(1, msg);
  if (max !== undefined) s = s.max(max, msg);
  return s;
};

// ------------------------------------------------------------
// 2. Enum schemas — map 1:1 to TS union types
// ------------------------------------------------------------

/** AC-S6-03: 14-state workflow. Message matches AC-S6-03 'Invalid status'. */
export const ContractStatusSchema = z.enum(
  [
    'draft',
    'in_review',
    'approved',
    'awaiting_signature_employer',
    'awaiting_signature_counterparty',
    'fully_signed',
    'active',
    'expiring_soon',
    'expired',
    'amended',
    'renewed',
    'terminated',
    'rejected',
    'resubmission_requested',
  ],
  { errorMap: () => ({ message: 'Invalid status' }) },
);

/** AC-S3-09 / AC-S4 invalid language. */
export const ContractLanguageSchema = z.enum(['en', 'ar', 'bilingual'], {
  errorMap: () => ({ message: 'Invalid language' }),
});

/** AC-S3-09 / AC-S4 invalid governing law. */
export const GoverningLawSchema = z.enum(
  ['uae_federal', 'dubai', 'abu_dhabi', 'sharjah', 'difc', 'adgm', 'english', 'other'],
  { errorMap: () => ({ message: 'Invalid governing law' }) },
);

/** AC-S3-09 / AC-S4 invalid relationship type. */
export const RelationshipTypeSchema = z.enum(
  ['amendment', 'renewal', 'extension', 'superseded', 'sow_under_msa'],
  { errorMap: () => ({ message: 'Invalid relationship type' }) },
);

export const ActivityTypeSchema = z.enum([
  'created',
  'updated',
  'status_changed',
  'version_created',
  'tagged',
  'soft_deleted',
  'restored',
]);

// ------------------------------------------------------------
// 3. Tag validation primitive (AC-S3-02 / AC-S8-05 / AC-S8-06)
// ------------------------------------------------------------

/**
 * Single tag string:
 *  - trimmed length 1..64           (AC-S3-02 / AC-S8-05)
 *  - no ASCII control characters    (AC-S8-06)
 */
// Detects ASCII control characters (0x00–0x1F) and DEL (0x7F).
// Implemented via codepoint scan to avoid the no-control-regex eslint rule.
const containsControlChar = (s: string): boolean => {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c <= 0x1f || c === 0x7f) return true;
  }
  return false;
};

const TagStringSchema = z
  .string()
  .transform((v) => v.trim())
  .pipe(
    z
      .string()
      .min(1, 'Each tag must be 1 to 64 characters')
      .max(64, 'Each tag must be 1 to 64 characters')
      .refine((v) => !containsControlChar(v), {
        message: 'Tag must not contain control characters',
      }),
  );

// ------------------------------------------------------------
// 4. CreateContractDtoSchema — POST /api/v1/contracts (S3)
// ------------------------------------------------------------

export const CreateContractDtoSchema = z
  .object({
    titleEn: NonEmptyString('Title (English) is required', 500), // AC-S3-04
    titleAr: z.string().trim().max(500).nullable().optional(),
    contractType: NonEmptyString('Contract type is required', 50), // AC-S3-05
    templateId: PositiveBigIntSchema.nullable().optional(),
    language: ContractLanguageSchema.optional().default('en'), // AC-S3-09
    ourPartyId: PositiveBigIntSchema.nullable().optional(),
    counterpartyId: PositiveBigIntSchema.nullable().optional(),
    valueAed: z
      .number({ invalid_type_error: 'Value must be greater than or equal to zero' })
      .nonnegative('Value must be greater than or equal to zero') // AC-S3-06
      .nullable()
      .optional(),
    currency: z.string().length(3).optional().default('AED'),
    startDate: IsoDateSchema.nullable().optional(),
    endDate: IsoDateSchema.nullable().optional(),
    expiryNoticeDays: z.number().int().min(0).optional().default(30),
    emirate: z.string().trim().max(50).nullable().optional(),
    governingLaw: GoverningLawSchema.nullable().optional(), // AC-S3-09
    jurisdictionCourt: z.string().trim().max(255).nullable().optional(),
    parentContractId: PositiveBigIntSchema.nullable().optional(),
    relationshipType: RelationshipTypeSchema.nullable().optional(), // AC-S3-09
    bodyEn: z.string().nullable().optional(),
    bodyAr: z.string().nullable().optional(),
    tags: z.array(TagStringSchema).optional(), // AC-S3-02

    // ---- M1c additive extension (Q3-OI-A / OI-2 / AC-S5-08 + AC-S7-04) ----
    // The bulk-import flow per AC-S5-08 / AC-S7-04 calls POST /api/v1/contracts
    // with these extra keys. All optional; target M1a-shipped columns on
    // contract (import_batch_id, import_filename, import_confidence,
    // import_warnings). No fn_ change required — fn_contract_create accepts
    // them via the JSONB payload. Existing M1a callers omit them — safe.
    importBatchId: PositiveBigIntSchema.nullable().optional(),
    importFilename: z.string().trim().max(500).nullable().optional(),
    importConfidence: z
      .number({ invalid_type_error: 'importConfidence must be in range 0..100' })
      .int()
      .min(0, 'importConfidence must be in range 0..100')
      .max(100, 'importConfidence must be in range 0..100')
      .nullable()
      .optional(),
    importWarnings: z.array(z.string().max(1000)).nullable().optional(),
  })
  .superRefine((val, ctx) => {
    // AC-S3-07: end date must be on or after start date
    if (val.startDate && val.endDate) {
      const start = new Date(val.startDate.slice(0, 10));
      const end = new Date(val.endDate.slice(0, 10));
      if (end < start) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['endDate'],
          message: 'End date must be on or after start date',
        });
      }
    }
  });
export type CreateContractDtoInferred = z.infer<typeof CreateContractDtoSchema>;

// ------------------------------------------------------------
// 5. UpdateContractDtoSchema — PUT /api/v1/contracts/:id (S4)
// ------------------------------------------------------------

export const UpdateContractDtoSchema = z
  .object({
    titleEn: NonEmptyString('Title (English) is required', 500).optional(),
    titleAr: z.string().trim().max(500).nullable().optional(),
    contractType: NonEmptyString('Contract type is required', 50).optional(),
    templateId: PositiveBigIntSchema.nullable().optional(),
    language: ContractLanguageSchema.optional(),
    ourPartyId: PositiveBigIntSchema.nullable().optional(),
    counterpartyId: PositiveBigIntSchema.nullable().optional(),
    valueAed: z
      .number({ invalid_type_error: 'Value must be greater than or equal to zero' })
      .nonnegative('Value must be greater than or equal to zero')
      .nullable()
      .optional(),
    currency: z.string().length(3).optional(),
    startDate: IsoDateSchema.nullable().optional(),
    endDate: IsoDateSchema.nullable().optional(),
    expiryNoticeDays: z.number().int().min(0).optional(),
    emirate: z.string().trim().max(50).nullable().optional(),
    governingLaw: GoverningLawSchema.nullable().optional(),
    jurisdictionCourt: z.string().trim().max(255).nullable().optional(),
    parentContractId: PositiveBigIntSchema.nullable().optional(),
    relationshipType: RelationshipTypeSchema.nullable().optional(),
    bodyEn: z.string().nullable().optional(),
    bodyAr: z.string().nullable().optional(),
  })
  // AC-S4-04: status must NOT be present.
  .strict()
  .superRefine((val, ctx) => {
    const anyVal = val as Record<string, unknown>;
    if ('status' in anyVal) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['status'],
        message: 'Use fn_contract_status_update to change status',
      });
    }
    // AC-S4-07: end date must be on or after start date (when both present)
    if (val.startDate && val.endDate) {
      const start = new Date(val.startDate.slice(0, 10));
      const end = new Date(val.endDate.slice(0, 10));
      if (end < start) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['endDate'],
          message: 'End date must be on or after start date',
        });
      }
    }
  });
export type UpdateContractDtoInferred = z.infer<typeof UpdateContractDtoSchema>;

// ------------------------------------------------------------
// 6. UpdateContractStatusDtoSchema — PATCH /:id/status (S6)
// ------------------------------------------------------------

export const UpdateContractStatusDtoSchema = z.object({
  newStatus: ContractStatusSchema, // AC-S6-03
  reason: z.string().trim().max(2000).nullable().optional(),
});
export type UpdateContractStatusDtoInferred = z.infer<typeof UpdateContractStatusDtoSchema>;

// ------------------------------------------------------------
// 7. SetContractTagsDtoSchema — PUT /:id/tags (S8)
// ------------------------------------------------------------

export const SetContractTagsDtoSchema = z.object({
  tags: z.array(TagStringSchema), // AC-S8-05/06
  // empty array is valid (AC-S8-03 — clears all tags)
});
export type SetContractTagsDtoInferred = z.infer<typeof SetContractTagsDtoSchema>;

// ------------------------------------------------------------
// 8. CreateContractVersionDtoSchema — POST /:id/versions (S10)
// ------------------------------------------------------------

export const CreateContractVersionDtoSchema = z
  .object({
    bodyEn: z.string().nullable().optional(),
    bodyAr: z.string().nullable().optional(),
    diffSummary: z.string().nullable().optional(),
    changeNote: NonEmptyString('Change note is required', 500), // AC-S10-05
  })
  .superRefine((val, ctx) => {
    // AC-S10-04: at least one of bodyEn or bodyAr must be provided.
    const hasEn = typeof val.bodyEn === 'string' && val.bodyEn.length > 0;
    const hasAr = typeof val.bodyAr === 'string' && val.bodyAr.length > 0;
    if (!hasEn && !hasAr) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['body'],
        message: 'At least one of bodyEn or bodyAr must be provided',
      });
    }
  });
export type CreateContractVersionDtoInferred = z.infer<typeof CreateContractVersionDtoSchema>;

// ------------------------------------------------------------
// 9. Path parameter schema — :id
// ------------------------------------------------------------

/** Path :id param for /api/v1/contracts/:id. */
export const ContractIdParamSchema = z.object({
  id: PositiveBigIntSchema,
});
export type ContractIdParamInferred = z.infer<typeof ContractIdParamSchema>;

// ------------------------------------------------------------
// 10. Query parameter schemas
// ------------------------------------------------------------

/**
 * GET /api/v1/contracts query params.
 */
export const ContractListQuerySchema = z.object({
  page: z.coerce.number().int().min(1, 'Page must be >= 1').optional().default(1),
  limit: z.coerce
    .number()
    .int()
    .min(1, 'Limit must be between 1 and 100')
    .max(100, 'Limit must be between 1 and 100')
    .optional()
    .default(20),
  status: ContractStatusSchema.optional(),
  contractType: z.string().trim().max(50).optional(),
  counterpartyId: PositiveBigIntSchema.optional(),
  draftedBy: PositiveBigIntSchema.optional(),
  approvedBy: PositiveBigIntSchema.optional(),
  startDateFrom: IsoDateSchema.optional(),
  startDateTo: IsoDateSchema.optional(),
  endDateFrom: IsoDateSchema.optional(),
  endDateTo: IsoDateSchema.optional(),
  /**
   * tags can arrive as repeated query params (?tags=a&tags=b) or comma list.
   */
  tags: z.preprocess((v) => {
    if (v === undefined || v === null) return undefined;
    if (Array.isArray(v)) return v;
    if (typeof v === 'string') {
      return v.includes(',') ? v.split(',').map((s) => s.trim()) : [v];
    }
    return v;
  }, z.array(TagStringSchema).optional()),
  search: z.string().trim().max(500).optional(),

  // ---- M1c additive extension (AE-1) ----
  // fn_contract_list 18-param signature accepts 3 new optional filter
  // params for review queue (S6) + admin batch drill-down (S4).
  importBatchId: PositiveBigIntSchema.optional(),
  importConfidenceMin: z.coerce
    .number()
    .int()
    .min(0, 'importConfidenceMin must be in range 0..100')
    .max(100, 'importConfidenceMin must be in range 0..100')
    .optional(),
  importConfidenceMax: z.coerce
    .number()
    .int()
    .min(0, 'importConfidenceMax must be in range 0..100')
    .max(100, 'importConfidenceMax must be in range 0..100')
    .optional(),
});
export type ContractListQueryInferred = z.infer<typeof ContractListQuerySchema>;

/** GET /api/v1/contracts/:id/versions query params. */
export const ContractVersionListQuerySchema = z.object({
  page: z.coerce.number().int().min(1, 'Page must be >= 1').optional().default(1),
  limit: z.coerce
    .number()
    .int()
    .min(1, 'Limit must be between 1 and 100')
    .max(100, 'Limit must be between 1 and 100')
    .optional()
    .default(20),
});
export type ContractVersionListQueryInferred = z.infer<typeof ContractVersionListQuerySchema>;

/** GET /api/v1/contracts/:id/activity query params. */
export const ContractActivityListQuerySchema = z.object({
  page: z.coerce.number().int().min(1, 'Page must be >= 1').optional().default(1),
  limit: z.coerce
    .number()
    .int()
    .min(1, 'Limit must be between 1 and 100')
    .max(100, 'Limit must be between 1 and 100')
    .optional()
    .default(50),
  activityType: ActivityTypeSchema.optional(),
});
export type ContractActivityListQueryInferred = z.infer<typeof ContractActivityListQuerySchema>;

// ------------------------------------------------------------
// 11. fn_ INPUT JSONB schemas — used by tests to construct fn_ p_data
// ------------------------------------------------------------

export const FnContractCreatePDataSchema = CreateContractDtoSchema;
export const FnContractUpdatePDataSchema = UpdateContractDtoSchema;
export const FnContractVersionCreatePDataSchema = CreateContractVersionDtoSchema;
