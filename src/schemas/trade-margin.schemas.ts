/**
 * CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
 * Zod validation schemas.
 *
 * Derived from contracts.md Part 3 endpoint specifications.
 * All enum values lock DB CHECK constraints.
 */
import { z } from 'zod';

// ---------------------------------------------------------------------------
// Shared enum / literal sets (DB-locked)
// ---------------------------------------------------------------------------

const tradeSideEnum = z.enum(['sell', 'buy']);
const tradeGradeEnum = z.enum(['murban', 'west_african_x', 'brent', 'dubai', 'wti', 'other']);
const tradeStatusEnum = z.enum(['open', 'priced', 'closed']);
const benchmarkCodeEnum = z.enum(['murban_osp', 'brent', 'dubai', 'wti', 'west_african_x', 'usd_aed']);
const benchmarkUnitEnum = z.enum(['usd_per_bbl', 'aed_per_usd']);
const periodGrainEnum = z.enum(['monthly', 'daily', 'spot']);
const benchmarkSourceEnum = z.enum(['osp_official', 'market', 'mock']);

/** ISO date string YYYY-MM-DD regex — used for date filter params and body fields. */
const isoDateRegex = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Non-negative numeric value — accepts string or number, coerces to string.
 * Preserves NUMERIC(12,4) precision across JSON boundary (no JS float coercion).
 */
const nonNegativeMoneySchema = z
  .union([z.string(), z.number()])
  .transform((v) => String(v))
  .refine(
    (v) => !isNaN(parseFloat(v)) && parseFloat(v) >= 0,
    { message: 'Value must be a non-negative number' },
  );

// ---------------------------------------------------------------------------
// Path param schemas
// ---------------------------------------------------------------------------

export const positionIdParamSchema = z.object({
  positionId: z.coerce
    .number({ invalid_type_error: 'positionId must be a number' })
    .int()
    .positive('positionId must be a positive integer'),
});

// ---------------------------------------------------------------------------
// Query schemas
// ---------------------------------------------------------------------------

/** GET /api/v1/financial/trade-margin */
export const tradePositionListQuerySchema = z.object({
  side:   tradeSideEnum.optional(),
  grade:  tradeGradeEnum.optional(),
  status: tradeStatusEnum.optional(),
  search: z.string().max(200).optional(),
  page:   z.coerce.number().int().min(1).default(1),
  limit:  z.coerce.number().int().min(1).max(200).default(50),
});

/** GET /api/v1/financial/trade-margin/aggregate */
export const marginAggregateQuerySchema = z.object({
  groupBy: z.enum(['counterparty', 'quarter', 'side']).optional().default('side'),
});

/** GET /api/v1/financial/trade-margin/:positionId/history */
export const marginSnapshotHistoryQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(500).default(50),
});

/** GET /api/v1/financial/price-benchmarks */
export const priceBenchmarkListQuerySchema = z.object({
  benchmarkCode: benchmarkCodeEnum.optional(),
  from:          z.string().regex(isoDateRegex, 'from must be in YYYY-MM-DD format').optional(),
  to:            z.string().regex(isoDateRegex, 'to must be in YYYY-MM-DD format').optional(),
  page:          z.coerce.number().int().min(1).default(1),
  limit:         z.coerce.number().int().min(1).max(500).default(100),
});

// ---------------------------------------------------------------------------
// Body schemas
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/financial/price-benchmarks/recompute
 * The OSP-drop demo action: set new benchmark price → recompute all open forward positions.
 */
export const recomputePriceBenchmarkSchema = z.object({
  benchmarkCode: benchmarkCodeEnum,
  newPrice:      nonNegativeMoneySchema.refine(
    (v) => parseFloat(v) >= 0,
    { message: 'newPrice must be non-negative' },
  ),
  priceDate: z
    .string()
    .regex(isoDateRegex, 'priceDate must be in YYYY-MM-DD format')
    .optional(),
});

/**
 * POST /api/v1/financial/price-benchmarks
 * Record or upsert a price benchmark observation.
 */
export const recordPriceBenchmarkSchema = z.object({
  benchmarkCode: benchmarkCodeEnum,
  priceDate:     z.string().regex(isoDateRegex, 'priceDate must be in YYYY-MM-DD format'),
  priceValue:    nonNegativeMoneySchema.refine(
    (v) => parseFloat(v) >= 0,
    { message: 'priceValue must be non-negative' },
  ),
  unit:        benchmarkUnitEnum,
  periodGrain: periodGrainEnum.optional().default('monthly'),
  source:      benchmarkSourceEnum.optional().default('mock'),
  notes:       z.string().max(2000).nullable().optional(),
});

// ---------------------------------------------------------------------------
// Exported inferred types
// ---------------------------------------------------------------------------

export type TradePositionListQueryInput      = z.infer<typeof tradePositionListQuerySchema>;
export type MarginAggregateQueryInput        = z.infer<typeof marginAggregateQuerySchema>;
export type MarginSnapshotHistoryQueryInput  = z.infer<typeof marginSnapshotHistoryQuerySchema>;
export type PriceBenchmarkListQueryInput     = z.infer<typeof priceBenchmarkListQuerySchema>;
export type RecomputePriceBenchmarkInput     = z.infer<typeof recomputePriceBenchmarkSchema>;
export type RecordPriceBenchmarkInput        = z.infer<typeof recordPriceBenchmarkSchema>;
export type PositionIdParamInput             = z.infer<typeof positionIdParamSchema>;
