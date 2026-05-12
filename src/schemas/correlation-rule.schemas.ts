/**
 * M13 / CR-E — Correlation Rule Engine Zod schemas.
 *
 * Derived from api-contracts.json (CR-E-001 through CR-E-008).
 * All schemas are strict — no z.any() used.
 */
import { z } from 'zod';

// ============================================================
// Path params
// ============================================================

export const RuleIdParamsSchema = z.object({
  id: z.coerce.number().int().min(1),
});

export const CorrelationIdParamsSchema = z.object({
  id: z.coerce.number().int().min(1),
});

// ============================================================
// CR-E-001 — List rules (query params)
// ============================================================

export const RuleListQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
  enabled: z.coerce.boolean().optional(),
  scenario: z.string().max(100).optional(),
  search: z.string().max(200).optional(),
});

export type RuleListQueryInput = z.infer<typeof RuleListQuerySchema>;

// ============================================================
// CR-E-002 — Create correlation rule (POST body)
// ============================================================

export const CreateRuleBodySchema = z.object({
  ruleId: z.string().min(1, 'ruleId is required').max(200),
  name: z.string().min(1, 'name is required').max(200),
  nameAr: z.string().min(1, 'nameAr is required').max(200),
  scenario: z.string().max(100).nullable().optional(),
  enabled: z.boolean().default(true),
  matchYaml: z.string().min(1, 'matchYaml is required'),
  produceYaml: z.string().min(1, 'produceYaml is required'),
  meta: z.record(z.unknown()).optional(),
});

export type CreateRuleBodyInput = z.infer<typeof CreateRuleBodySchema>;

// ============================================================
// CR-E-003 — Update correlation rule (PATCH body)
// ============================================================

export const UpdateRuleBodySchema = z
  .object({
    name: z.string().max(200).optional(),
    nameAr: z.string().max(200).optional(),
    scenario: z.string().max(100).nullable().optional(),
    enabled: z.boolean().optional(),
    matchYaml: z.string().optional(),
    produceYaml: z.string().optional(),
    meta: z.record(z.unknown()).optional(),
  })
  .refine((obj) => Object.keys(obj).length > 0, {
    message: 'At least one field required for update',
  });

export type UpdateRuleBodyInput = z.infer<typeof UpdateRuleBodySchema>;

// ============================================================
// CR-E-004 — Test rule against fixture (POST body)
// ============================================================

export const TestRuleBodySchema = z.object({
  // FE sends fixture PK as the HTML <select> option value (string).
  // Accept either string or number; controller coerces to bigint.
  fixtureId: z.union([z.string(), z.number()]).optional(),
});

export type TestRuleBodyInput = z.infer<typeof TestRuleBodySchema>;

// ============================================================
// CR-E-005 — List correlations (query params)
// ============================================================

export const CorrelationListQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
  contractId: z.coerce.number().int().min(1).optional(),
  status: z.enum(['active', 'dismissed', 'expired']).optional(),
  ruleId: z.string().optional(),
  fromDate: z.string().date().optional(),
  toDate: z.string().date().optional(),
});

export type CorrelationListQueryInput = z.infer<typeof CorrelationListQuerySchema>;

// ============================================================
// CR-E-006 — Dismiss correlation (POST body)
// ============================================================

export const CorrelationDismissBodySchema = z.object({
  reason: z
    .string()
    .min(10, 'reason must be at least 10 characters')
    .max(2000, 'reason cannot exceed 2000 characters'),
});

export type CorrelationDismissBodyInput = z.infer<typeof CorrelationDismissBodySchema>;
