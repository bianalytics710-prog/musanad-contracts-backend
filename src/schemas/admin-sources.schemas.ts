// ============================================================
// M7 — Zod schemas for /api/v1/admin/sources/* + /api/v1/admin/source-health
//
// Mirrors db-design.md §2 fn_ parameter specs + types.ts DTOs.
// Stage 4 BE-01 / S2-25 alignment: every controller call validates body /
// query / params before db.callFunction().
// ============================================================
import { z } from 'zod';

// ------------------------------------------------------------
// Path params
// ------------------------------------------------------------

export const osintSourceIdParamSchema = z.object({
  id: z.coerce.number().int().positive('id must be a positive integer'),
});
export type OsintSourceIdParamInferred = z.infer<typeof osintSourceIdParamSchema>;

// ------------------------------------------------------------
// Enums (mirror db-design.md §1.2 / §1.4 CHECK constraints)
// ------------------------------------------------------------

export const sourceKindSchema = z.enum(
  ['sanctions', 'news', 'weather', 'commodity', 'fx', 'social', 'regulatory', 'internal'],
  { errorMap: () => ({ message: 'Invalid kind value' }) },
);

export const sourceFormatSchema = z.enum(['xml', 'csv', 'json', 'rss', 'api'], {
  errorMap: () => ({ message: 'Invalid format value' }),
});

export const healthStateSchema = z.enum(['healthy', 'degraded', 'failing', 'unauthorised'], {
  errorMap: () => ({ message: 'Invalid state value' }),
});

export const dataClassificationSchema = z.enum(['demo', 'pilot', 'production'], {
  errorMap: () => ({ message: 'Invalid dataClassification value' }),
});

export const credentialKindSchema = z.enum(['api_key', 'oauth_token', 'basic_auth', 'none'], {
  errorMap: () => ({ message: 'Invalid credentialKind value' }),
});

// ------------------------------------------------------------
// Embedded JSONB shapes (loose validation — fn_ does authoritative checks)
// ------------------------------------------------------------

const rateLimitConfigSchema = z.object({
  callsPerMinute: z.number().int().positive(),
  burst: z.number().int().nonnegative(),
  minIntervalMs: z.number().int().nonnegative(),
  respectRetryAfter: z.boolean(),
});

const severityEnumSchema = z.enum(['informational', 'low', 'medium', 'high', 'critical']);

const severityMappingRuleSchema = z
  .object({
    programContains: z.string().optional(),
    titleContains: z.string().optional(),
    absChangePctGte: z.number().optional(),
    pegDeviationPctGte: z.number().optional(),
    default: severityEnumSchema.optional(),
    severity: severityEnumSchema.optional(),
  })
  .strict();

const severityMappingSchema = z.object({
  rules: z.array(severityMappingRuleSchema),
});

const geographyFilterSchema = z
  .object({
    countryIn: z.array(z.string()).optional(),
    themeIn: z.array(z.string()).optional(),
    actorIn: z.array(z.string()).optional(),
  })
  .strict();

// ------------------------------------------------------------
// GET /api/v1/admin/sources query
// ------------------------------------------------------------

export const osintSourceListQuerySchema = z.object({
  page: z.coerce.number().int().min(1).optional(),
  limit: z.coerce.number().int().min(1).max(100).optional(),
  kind: sourceKindSchema.optional(),
  state: healthStateSchema.optional(),
  search: z.string().trim().min(1).max(200).optional(),
});
export type OsintSourceListQueryInferred = z.infer<typeof osintSourceListQuerySchema>;

// ------------------------------------------------------------
// POST /api/v1/admin/sources body
// ------------------------------------------------------------

export const createOsintSourceSchema = z.object({
  sourceId: z
    .string()
    .trim()
    .min(1, 'sourceId is required')
    .max(200, 'sourceId must be at most 200 chars'),
  displayName: z
    .string()
    .trim()
    .min(1, 'displayName is required')
    .max(200, 'displayName must be at most 200 chars'),
  displayNameAr: z.string().trim().max(200).optional(),
  kind: sourceKindSchema,
  url: z.string().trim().max(2000).optional(),
  format: sourceFormatSchema,
  refreshSeconds: z
    .number()
    .int()
    .min(60, 'refreshSeconds must be at least 60'),
  sourceReliability: z
    .number()
    .min(0, 'sourceReliability must be between 0 and 1')
    .max(1, 'sourceReliability must be between 0 and 1'),
  enabled: z.boolean().optional(),
  rateLimit: rateLimitConfigSchema.nullable().optional(),
  severityMapping: severityMappingSchema.nullable().optional(),
  geographyFilter: geographyFilterSchema.nullable().optional(),
  licensingNote: z.string().max(2000).optional(),
  metadata: z.record(z.unknown()).optional(),
  dataClassification: dataClassificationSchema.optional(),
});
export type CreateOsintSourceInferred = z.infer<typeof createOsintSourceSchema>;

// ------------------------------------------------------------
// PATCH /api/v1/admin/sources/:id body
//   - All fields optional (partial update)
//   - sourceId is REJECTED if present (immutable per AC-S3-08).
//     Schema-level guard via .strict() + explicit refusal — fn_ also rejects.
// ------------------------------------------------------------

export const updateOsintSourceSchema = z
  .object({
    displayName: z.string().trim().min(1).max(200).optional(),
    displayNameAr: z.string().trim().max(200).optional(),
    kind: sourceKindSchema.optional(),
    url: z.string().trim().max(2000).optional(),
    format: sourceFormatSchema.optional(),
    refreshSeconds: z.number().int().min(60).optional(),
    sourceReliability: z.number().min(0).max(1).optional(),
    enabled: z.boolean().optional(),
    rateLimit: rateLimitConfigSchema.nullable().optional(),
    severityMapping: severityMappingSchema.nullable().optional(),
    geographyFilter: geographyFilterSchema.nullable().optional(),
    licensingNote: z.string().max(2000).optional(),
    metadata: z.record(z.unknown()).optional(),
    dataClassification: dataClassificationSchema.optional(),
    // sourceId trap — present in payload triggers AC-S3-08
    sourceId: z
      .never({
        invalid_type_error: 'sourceId is immutable',
      })
      .optional(),
  })
  .refine((data) => Object.keys(data).length > 0, {
    message: 'At least one field must be provided for update',
  });
export type UpdateOsintSourceInferred = z.infer<typeof updateOsintSourceSchema>;

// ------------------------------------------------------------
// POST /api/v1/admin/sources/:id/credential body
// ------------------------------------------------------------

export const setCredentialSchema = z.object({
  credentialKind: credentialKindSchema,
  credentialRef: z
    .string()
    .trim()
    .min(3, 'credentialRef must be at least 3 chars')
    .max(500, 'credentialRef must be at most 500 chars')
    .regex(
      /^(env:|vault:)/,
      'credentialRef must use env: or vault: scheme',
    ),
});
export type SetCredentialInferred = z.infer<typeof setCredentialSchema>;
