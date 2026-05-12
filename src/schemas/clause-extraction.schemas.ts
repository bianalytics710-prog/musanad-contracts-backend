/**
 * M12 / CR-D — Clause Extraction + Taxonomy + Review Zod schemas.
 *
 * Derived from api-contracts.json (CR-D-001 through CR-D-006).
 * All schemas are strict — no z.any() used.
 */
import { z } from 'zod';

// ============================================================
// Path params
// ============================================================

export const ContractIdParamsSchema = z.object({
  id: z.coerce.number().int().min(1),
});

export const ContractVersionParamsSchema = z.object({
  id: z.coerce.number().int().min(1),
  vId: z.coerce.number().int().min(1),
});

export const ClauseIdParamsSchema = z.object({
  id: z.coerce.number().int().min(1),
});

// ============================================================
// CR-D-001 / CR-D-002 — Trigger clause extraction
// ============================================================

export const ExtractClausesBodySchema = z.object({
  forceReprocess: z.boolean().optional(),
});

export type ExtractClausesBodyInput = z.infer<typeof ExtractClausesBodySchema>;

// ============================================================
// CR-D-003 — Clause review queue list (query params)
// ============================================================

export const ClauseReviewQueueQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
  contractId: z.coerce.number().int().min(1).optional(),
  clauseType: z.string().optional(),
  reviewStatus: z
    .enum(['auto', 'pending_review', 'reviewed', 'rejected', 'pending_extraction'])
    .optional(),
  confidenceBelow: z.coerce.number().min(0).max(1).optional(),
});

export type ClauseReviewQueueQueryInput = z.infer<typeof ClauseReviewQueueQuerySchema>;

// ============================================================
// CR-D-004 — Clause review resolve (POST body)
// ============================================================

export const ClauseReviewBodySchema = z
  .object({
    action: z.enum(['confirm', 'correct', 'reject']),
    parametersCorrection: z.record(z.unknown()).optional(),
    textExcerptsCorrection: z.record(z.string()).optional(),
  })
  .superRefine((data, ctx) => {
    if (data.action === 'correct' && !data.parametersCorrection) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'parametersCorrection is required when action is correct',
        path: ['parametersCorrection'],
      });
    }
    if (data.action === 'correct' && !data.textExcerptsCorrection) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'textExcerptsCorrection is required when action is correct',
        path: ['textExcerptsCorrection'],
      });
    }
  });

export type ClauseReviewBodyInput = z.infer<typeof ClauseReviewBodySchema>;

// ============================================================
// CR-D-005 — Clause taxonomy list (query params)
// ============================================================

export const ClauseTaxonomyQuerySchema = z.object({
  family: z
    .enum([
      'force_majeure',
      'termination',
      'pricing',
      'performance',
      'indemnity',
      'compliance',
      'governance',
      'operational',
    ])
    .optional(),
  search: z.string().max(200).optional(),
  isActive: z.coerce.boolean().default(true),
});

export type ClauseTaxonomyQueryInput = z.infer<typeof ClauseTaxonomyQuerySchema>;

// ============================================================
// CR-D-006 — Clause semantic search (POST body)
// ============================================================

export const ClauseSemanticSearchBodySchema = z.object({
  queryText: z.string().min(3, 'queryText must be at least 3 characters').max(1000),
  contractId: z.coerce.number().int().min(1).optional(),
  limit: z.number().int().min(1).max(50).default(10),
  similarityMin: z.number().min(0).max(1).default(0.0),
});

export type ClauseSemanticSearchBodyInput = z.infer<typeof ClauseSemanticSearchBodySchema>;
