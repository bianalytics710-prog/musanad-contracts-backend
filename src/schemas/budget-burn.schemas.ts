/**
 * CR-N — Budget Burn Zod validation schemas.
 * Derived from contracts.md Part 3 endpoint specifications.
 */
import { z } from 'zod';

// ---------------------------------------------------------------------------
// Shared enum / literal sets
// ---------------------------------------------------------------------------

const costCategoryEnum = z.enum(['day_rate', 'manpower', 'equipment', 'milestone', 'other']);
const periodTypeEnum = z.enum(['month', 'quarter', 'year']);
const actualSourceEnum = z.enum(['erp_feed', 'manual']);

// ---------------------------------------------------------------------------
// Path param schemas
// ---------------------------------------------------------------------------

export const contractIdParamSchema = z.object({
  contractId: z.coerce.number({ invalid_type_error: 'contractId must be a number' }).int().positive('contractId must be a positive integer'),
});

export const budgetIdParamSchema = z.object({
  id: z.coerce.number({ invalid_type_error: 'id must be a number' }).int().positive('id must be a positive integer'),
});

// ---------------------------------------------------------------------------
// Query schemas
// ---------------------------------------------------------------------------

export const budgetBurnVarianceQuerySchema = z.object({
  thresholdPct: z.coerce.number().min(0).max(100).optional(),
});

export const budgetProjectionQuerySchema = z.object({
  asOfPeriod: z.string().regex(/^\d{4}-\d{2}$/, 'asOfPeriod must be in YYYY-MM format').optional(),
});

export const portfolioQuerySchema = z.object({
  fiscalYear:     z.coerce.number().int().min(2000).max(2100).optional(),
  minVariancePct: z.coerce.number().min(0).optional(),
  costCategory:   costCategoryEnum.optional(),
  page:           z.coerce.number().int().min(1).default(1),
  limit:          z.coerce.number().int().min(1).max(100).default(20),
});

export const budgetListQuerySchema = z.object({
  contractId:   z.coerce.number().int().positive().optional(),
  fiscalYear:   z.coerce.number().int().min(2000).max(2100).optional(),
  costCategory: costCategoryEnum.optional(),
  page:         z.coerce.number().int().min(1).default(1),
  limit:        z.coerce.number().int().min(1).max(100).default(50),
});

export const costActualListQuerySchema = z.object({
  contractId:   z.coerce.number().int().positive().optional(),
  fiscalYear:   z.coerce.number().int().min(2000).max(2100).optional(),
  costCategory: costCategoryEnum.optional(),
  periodLabel:  z.string().optional(),
  page:         z.coerce.number().int().min(1).default(1),
  limit:        z.coerce.number().int().min(1).max(100).default(50),
});

// ---------------------------------------------------------------------------
// Body schemas
// ---------------------------------------------------------------------------

export const recordCostActualSchema = z.object({
  /**
   * Period label in YYYY-MM format for month grain (default).
   */
  periodLabel: z.string().regex(/^\d{4}-\d{2}$/, 'periodLabel must be in YYYY-MM format (month grain)'),
  fiscalYear: z.number({ required_error: 'fiscalYear is required' }).int().min(2000).max(2100),
  costCategory: costCategoryEnum,
  /**
   * Non-negative amount. String or number accepted; coerced to string
   * for NUMERIC(18,2) DB precision preservation.
   * DESIGN NOTE 2 (contracts.md): referenceNo NOT NULL DEFAULT '' — coalesced below.
   */
  actualAmountAed: z
    .union([z.string(), z.number()])
    .transform((v) => String(v))
    .refine(
      (v) => !isNaN(parseFloat(v)) && parseFloat(v) >= 0,
      { message: 'actualAmountAed must be a non-negative number' },
    ),
  source:      actualSourceEnum.optional().default('manual'),
  /**
   * ERP voucher/invoice ref. Part of idempotency key.
   * Coalesced to '' if absent (DB column NOT NULL DEFAULT '').
   */
  referenceNo: z.string().max(100).optional().transform((v) => v ?? ''),
  periodType:  periodTypeEnum.optional().default('month'),
  notes:       z.string().max(2000).nullable().optional(),
});

export const draftCureNoticeSchema = z.object({
  thresholdPct:     z.number().min(0).max(100).optional(),
  focusPeriodLabel: z.string().optional(),
});

// ---------------------------------------------------------------------------
// Exported inferred types
// ---------------------------------------------------------------------------

export type BudgetBurnVarianceQueryInput   = z.infer<typeof budgetBurnVarianceQuerySchema>;
export type BudgetProjectionQueryInput     = z.infer<typeof budgetProjectionQuerySchema>;
export type PortfolioQueryInput            = z.infer<typeof portfolioQuerySchema>;
export type BudgetListQueryInput           = z.infer<typeof budgetListQuerySchema>;
export type CostActualListQueryInput       = z.infer<typeof costActualListQuerySchema>;
export type RecordCostActualInput          = z.infer<typeof recordCostActualSchema>;
export type DraftCureNoticeInput           = z.infer<typeof draftCureNoticeSchema>;
