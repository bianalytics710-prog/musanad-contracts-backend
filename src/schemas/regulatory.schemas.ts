// ============================================================
// M5 — Regulatory Radar — Zod Validation Schemas (BE)
// Mirrors workspace/current-module/schemas.ts (canonical Agent 5 source).
// Local copy here so the backend repo is self-contained for tsc.
// Pattern: M3/M4 schemas (superRefine for cross-field validation).
// ============================================================

import { z } from 'zod';

// ------------------------------------------------------------
// 1. Shared enum schemas (must match DB CHECK enums byte-for-byte)
// ------------------------------------------------------------

export const regulationTypeSchema = z.enum([
  'federal_decree_law',
  'cabinet_resolution',
  'ministerial_decision',
  'free_zone_regulation',
  'circular',
  'guideline',
]);

export const regulationJurisdictionSchema = z.enum([
  'uae_federal',
  'dubai',
  'abu_dhabi',
  'sharjah',
  'difc',
  'adgm',
  'dmcc',
  'other',
]);

export const regulationStatusSchema = z.enum(['active', 'superseded', 'repealed', 'draft']);

export const regulatorySeveritySchema = z.enum(['low', 'medium', 'high', 'critical']);

export const regulatoryImpactResolutionActionSchema = z.enum([
  'amended',
  'waived',
  'out_of_scope',
  'pending',
]);

export const m5PermissionCodeSchema = z.enum([
  'regulations.read',
  'regulations.manage',
  'config.manage',
]);

// ------------------------------------------------------------
// 2. Pagination / common
// ------------------------------------------------------------

const paginationQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(20).optional(),
});

const isoDateSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Must be ISO date YYYY-MM-DD');

const positiveIntId = z.coerce.number().int().positive();

/** :id path-param schema — used by every detail/PATCH/DELETE route. */
export const regulatoryIdParamSchema = z.object({
  id: positiveIntId,
});
export type RegulatoryIdParamInput = z.infer<typeof regulatoryIdParamSchema>;

// ------------------------------------------------------------
// 3. regulation — list query / create / update
// ------------------------------------------------------------

export const regulationListQuerySchema = paginationQuerySchema.extend({
  jurisdiction: regulationJurisdictionSchema.optional(),
  regulationType: regulationTypeSchema.optional(),
  issuerId: positiveIntId.optional(),
  status: regulationStatusSchema.optional(),
  search: z.string().max(200).optional(),
});

export const createRegulationSchema = z.object({
  referenceCode: z.string().min(1).max(80),
  titleEn: z.string().min(1).max(500),
  titleAr: z.string().max(500).nullable().optional(),
  issuerId: z.number().int().positive(),
  regulationType: regulationTypeSchema,
  jurisdiction: regulationJurisdictionSchema.nullable().optional(),
  effectiveDate: isoDateSchema.nullable().optional(),
  summaryEn: z.string().max(20_000).nullable().optional(),
  summaryAr: z.string().max(20_000).nullable().optional(),
  sourceUrl: z.string().max(2000).nullable().optional(),
  tags: z.array(z.string().min(1).max(120)).max(60).optional(),
  status: regulationStatusSchema.optional(),
});

/**
 * Update DTO — partial; all fields optional. AC-S4-05 — referenceCode
 * immutable; fn raises 23501 if patched. We omit it from the schema
 * entirely (defence-in-depth at the type layer; controller passes through
 * if a client sends it, fn body raises).
 */
export const updateRegulationSchema = z
  .object({
    titleEn: z.string().min(1).max(500).optional(),
    titleAr: z.string().max(500).nullable().optional(),
    summaryEn: z.string().max(20_000).nullable().optional(),
    summaryAr: z.string().max(20_000).nullable().optional(),
    sourceUrl: z.string().max(2000).nullable().optional(),
    tags: z.array(z.string().min(1).max(120)).max(60).optional(),
    status: regulationStatusSchema.optional(),
    supersededById: z.number().int().positive().nullable().optional(),
    regulationType: regulationTypeSchema.optional(),
    jurisdiction: regulationJurisdictionSchema.nullable().optional(),
    effectiveDate: isoDateSchema.nullable().optional(),
    issuerId: z.number().int().positive().optional(),
  })
  .strict()
  .refine(
    (value) => Object.keys(value).length > 0,
    'At least one field must be provided to update',
  );

// ------------------------------------------------------------
// 4. regulatory_update — list query / create / update
// ------------------------------------------------------------

export const regulatoryUpdateListQuerySchema = paginationQuerySchema
  .extend({
    regulatorId: positiveIntId.optional(),
    severity: regulatorySeveritySchema.optional(),
    categoryId: positiveIntId.optional(),
    effectiveFrom: isoDateSchema.optional(),
    effectiveTo: isoDateSchema.optional(),
    complianceDeadlineMax: isoDateSchema.optional(),
  })
  .superRefine((value, ctx) => {
    if (value.effectiveFrom && value.effectiveTo && value.effectiveFrom > value.effectiveTo) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['effectiveFrom'],
        message: 'effectiveFrom must be on or before effectiveTo',
      });
    }
  });

export const createRegulatoryUpdateSchema = z
  .object({
    regulatorId: z.number().int().positive(),
    titleEn: z.string().min(1).max(500),
    titleAr: z.string().max(500).nullable().optional(),
    summaryEn: z.string().max(20_000).nullable().optional(),
    summaryAr: z.string().max(20_000).nullable().optional(),
    referenceNumber: z.string().max(120).nullable().optional(),
    publishedDate: isoDateSchema,
    effectiveDate: isoDateSchema.nullable().optional(),
    complianceDeadline: isoDateSchema.nullable().optional(),
    severity: regulatorySeveritySchema.optional(),
    sourceUrl: z.string().max(2000).nullable().optional(),
    affectedClauseCategories: z.array(z.string().min(1).max(120)).max(60).optional(),
    categoryId: z.number().int().positive().nullable().optional(),
    subSource: z.string().max(120).nullable().optional(),
  })
  .superRefine((value, ctx) => {
    // AC-S8-03 — defence-in-depth (DB CHECK + fn body also enforce).
    if (value.effectiveDate && value.effectiveDate < value.publishedDate) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['effectiveDate'],
        message: 'Effective date cannot be before published date',
      });
    }
    // AC-S8-04 — defence-in-depth.
    if (value.complianceDeadline && value.complianceDeadline < value.publishedDate) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['complianceDeadline'],
        message: 'Compliance deadline cannot be before published date',
      });
    }
  });

export const updateRegulatoryUpdateSchema = z
  .object({
    regulatorId: z.number().int().positive().optional(),
    titleEn: z.string().min(1).max(500).optional(),
    titleAr: z.string().max(500).nullable().optional(),
    summaryEn: z.string().max(20_000).nullable().optional(),
    summaryAr: z.string().max(20_000).nullable().optional(),
    referenceNumber: z.string().max(120).nullable().optional(),
    publishedDate: isoDateSchema.optional(),
    effectiveDate: isoDateSchema.nullable().optional(),
    complianceDeadline: isoDateSchema.nullable().optional(),
    severity: regulatorySeveritySchema.optional(),
    sourceUrl: z.string().max(2000).nullable().optional(),
    affectedClauseCategories: z.array(z.string().min(1).max(120)).max(60).optional(),
    categoryId: z.number().int().positive().nullable().optional(),
    subSource: z.string().max(120).nullable().optional(),
  })
  .strict()
  .refine(
    (value) => Object.keys(value).length > 0,
    'At least one field must be provided to update',
  );

// ------------------------------------------------------------
// 5. regulatory_impact — list query / bulk-detect / resolve
// ------------------------------------------------------------

export const regulatoryImpactListQuerySchema = paginationQuerySchema
  .extend({
    contractId: positiveIntId.optional(),
    regulationId: positiveIntId.optional(),
    regulatoryUpdateId: positiveIntId.optional(),
    resolved: z.coerce.boolean().optional(),
  })
  .superRefine((value, ctx) => {
    // AC-S12-02 — at least one scoping filter required.
    if (
      value.contractId === undefined &&
      value.regulationId === undefined &&
      value.regulatoryUpdateId === undefined
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['filters'],
        message: 'At least one of contractId, regulationId, regulatoryUpdateId is required',
      });
    }
  });

/** Per-contract payload entry inside impactPayload. SENSITIVE — pino-redacted. */
export const impactPayloadEntrySchema = z.object({
  impactScore: z.number().int().min(0).max(100).nullable().optional(),
  noteEn: z.string().max(2000).nullable().optional(),
  noteAr: z.string().max(2000).nullable().optional(),
  summaryEn: z.string().max(8000).nullable().optional(),
  summaryAr: z.string().max(8000).nullable().optional(),
});

export const bulkDetectRegulatoryImpactSchema = z
  .object({
    regulatoryUpdateId: z.number().int().positive(),
    regulationId: z.number().int().positive(),
    /** AC-S11-03 — at least one. Cap of 1000 to bound N for the FOR UPDATE loop. */
    contractIds: z
      .array(z.number().int().positive())
      .min(1, 'At least one contract required')
      .max(1000),
    /** Keys are stringified contract ids; values are per-contract payloads. */
    impactPayload: z.record(z.string(), impactPayloadEntrySchema),
  })
  .superRefine((value, ctx) => {
    // Defence-in-depth: every contractId must have a corresponding impactPayload key.
    for (const cid of value.contractIds) {
      if (!Object.prototype.hasOwnProperty.call(value.impactPayload, String(cid))) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['impactPayload'],
          message: `impactPayload missing entry for contractId ${cid}`,
        });
        break;
      }
    }
  });

export const resolveRegulatoryImpactSchema = z.object({
  resolutionAction: regulatoryImpactResolutionActionSchema,
  resolutionNote: z.string().max(8000).nullable().optional(),
});

// ------------------------------------------------------------
// 6. impact_category — list query / upsert
// ------------------------------------------------------------

export const impactCategoryListQuerySchema = z.object({
  includeInactive: z.coerce.boolean().default(false).optional(),
});

/**
 * Upsert DTO — keyed on `key`. AC-S15-01 minimum (key + nameEn + nameAr).
 * AC-S15-04 severity_scale must be array of strings (defence-in-depth — DB
 * CHECK chk_impact_category_severity_scale_array also enforces array
 * shape; fn body validates per-element string typeof).
 */
export const upsertImpactCategorySchema = z.object({
  key: z
    .string()
    .min(1)
    .max(60)
    .regex(/^[a-z][a-z0-9_]*$/, 'key must be snake_case (lowercase letters, digits, underscores)'),
  nameEn: z.string().min(1).max(200),
  /** AC-S15-03 — bilingual mandate. */
  nameAr: z.string().min(1).max(200),
  descriptionEn: z.string().max(20_000).nullable().optional(),
  descriptionAr: z.string().max(20_000).nullable().optional(),
  icon: z.string().min(1).max(60).optional(),
  colour: z.string().min(1).max(30).optional(),
  active: z.boolean().optional(),
  displayOrder: z.number().int().min(0).optional(),
  sources: z.array(z.string().min(1).max(120)).max(40).optional(),
  /** AC-S15-04 — must be array of strings. */
  severityScale: z.array(z.string().min(1).max(40)).min(1).max(10).optional(),
  aiPromptContext: z.string().max(20_000).nullable().optional(),
  defaultClauseCategories: z.array(z.string().min(1).max(120)).max(60).optional(),
});

// ============================================================
// 7. Inferred input types (re-exports for convenience)
// ============================================================

export type RegulationListQueryInput = z.infer<typeof regulationListQuerySchema>;
export type CreateRegulationInput = z.infer<typeof createRegulationSchema>;
export type UpdateRegulationInput = z.infer<typeof updateRegulationSchema>;

export type RegulatoryUpdateListQueryInput = z.infer<typeof regulatoryUpdateListQuerySchema>;
export type CreateRegulatoryUpdateInput = z.infer<typeof createRegulatoryUpdateSchema>;
export type UpdateRegulatoryUpdateInput = z.infer<typeof updateRegulatoryUpdateSchema>;

export type RegulatoryImpactListQueryInput = z.infer<typeof regulatoryImpactListQuerySchema>;
export type BulkDetectRegulatoryImpactInput = z.infer<typeof bulkDetectRegulatoryImpactSchema>;
export type ResolveRegulatoryImpactInput = z.infer<typeof resolveRegulatoryImpactSchema>;

export type ImpactCategoryListQueryInput = z.infer<typeof impactCategoryListQuerySchema>;
export type UpsertImpactCategoryInput = z.infer<typeof upsertImpactCategorySchema>;
