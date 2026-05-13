/**
 * M14 / CR-F — 5-Dim Risk Scoring + MaR + AVaR
 * Zod validation schemas for all CR-F request surfaces.
 *
 * Rules:
 *   - Never z.any() — every field typed explicitly.
 *   - Numeric query params use z.coerce.number() (query strings arrive as strings).
 *   - ID path params coerced to positive integer then re-serialized per BigInt convention.
 *   - Sensitive fields (weightsApplied, explanation, contributingCorrelations) never in logs.
 */
import { z } from 'zod';
import { HISTORY_WINDOW_DAYS_ALLOWED, AVAR_GROUP_BY_VALUES } from '../types/risk-score.types';

// ============================================================
// Path params
// ============================================================

/**
 * Path param schema for routes that take a contract :id.
 * BIGINT-as-string: coerced to number for positivity check, kept as string for BigInt safety.
 */
export const contractIdParamsSchema = z.object({
  id: z
    .string()
    .min(1, 'Contract ID is required')
    .refine((v) => {
      const n = Number(v);
      return Number.isInteger(n) && n > 0;
    }, 'Contract ID must be a positive integer'),
});

export type ContractIdParamsInput = z.infer<typeof contractIdParamsSchema>;

// ============================================================
// Query params
// ============================================================

/**
 * Query schema for GET /api/v1/contracts/:id/risk-score/history.
 * windowDays must be one of {30, 90, 180} — validated at Zod layer before DB call.
 * fn_risk_score_history also raises 22023 if outside set (belt-and-suspenders).
 * QA W2 note: type is INTEGER not a TS union type.
 */
export const getRiskScoreHistoryQuerySchema = z.object({
  windowDays: z
    .coerce.number()
    .int('windowDays must be an integer')
    .refine(
      (v): v is typeof HISTORY_WINDOW_DAYS_ALLOWED[number] =>
        (HISTORY_WINDOW_DAYS_ALLOWED as readonly number[]).includes(v),
      `windowDays must be one of ${HISTORY_WINDOW_DAYS_ALLOWED.join(', ')}`,
    )
    .default(90),
});

export type GetRiskScoreHistoryQueryInput = z.infer<typeof getRiskScoreHistoryQuerySchema>;

/**
 * Query schema for GET /api/v1/risk/avar.
 * All fields optional — absent means "no filter on this dimension".
 * groupBy defaults to 'business_unit'; windowDays defaults to 90.
 */
export const getAvarQuerySchema = z.object({
  businessUnit: z.string().optional(),
  counterpartyId: z.string().optional(),
  counterpartyChainRootId: z.string().optional(),
  geography: z.string().optional(),
  riskKind: z.string().optional(),
  groupBy: z
    .enum(['business_unit', 'counterparty_id', 'counterparty_chain', 'geography', 'risk_kind'] as const)
    .default('business_unit')
    .optional(),
  windowDays: z
    .coerce.number()
    .int('windowDays must be an integer')
    .min(1, 'windowDays must be at least 1')
    .max(365, 'windowDays must be at most 365')
    .default(90)
    .optional(),
});

export type GetAvarQueryInput = z.infer<typeof getAvarQuerySchema>;

// ============================================================
// Request body schemas
// ============================================================

/**
 * Request body schema for PATCH /api/v1/admin/scoring-weights.
 * All 5 dimension keys required, each in [0, 1].
 * Refinement: sum must be 1.0 ± 0.001 (AC-S7-02).
 * fn_scoring_weights_set also raises 22023 if sum is out of range (belt-and-suspenders).
 */
export const patchScoringWeightsBodySchema = z
  .object({
    legal: z
      .number({ required_error: 'legal weight is required' })
      .min(0, 'legal must be at least 0')
      .max(1, 'legal must be at most 1'),
    financial: z
      .number({ required_error: 'financial weight is required' })
      .min(0, 'financial must be at least 0')
      .max(1, 'financial must be at most 1'),
    operational: z
      .number({ required_error: 'operational weight is required' })
      .min(0, 'operational must be at least 0')
      .max(1, 'operational must be at most 1'),
    reputational: z
      .number({ required_error: 'reputational weight is required' })
      .min(0, 'reputational must be at least 0')
      .max(1, 'reputational must be at most 1'),
    compliance: z
      .number({ required_error: 'compliance weight is required' })
      .min(0, 'compliance must be at least 0')
      .max(1, 'compliance must be at most 1'),
  })
  .refine(
    (data) => {
      const total = data.legal + data.financial + data.operational + data.reputational + data.compliance;
      return Math.abs(total - 1.0) <= 0.001;
    },
    (data) => {
      const total = data.legal + data.financial + data.operational + data.reputational + data.compliance;
      return {
        message: `Weights must sum to 1.0 ± 0.001 (actual sum: ${total.toFixed(6)})`,
        path: ['weights.sum'],
      };
    },
  );

export type PatchScoringWeightsBodyInput = z.infer<typeof patchScoringWeightsBodySchema>;
