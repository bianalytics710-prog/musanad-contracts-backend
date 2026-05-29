// ============================================================
// CR-N — Services-Contract Budget Burn (M21 Financial Intelligence)
// TypeScript Type Definitions
// Derived from: db-design.md §C, §D (Agent 4 output)
// Do not edit manually — regenerate via Agent 5 if DB design changes.
// ============================================================

import type { ApiResponse, PaginationMeta } from './api.types';

// -----------------------------------------------------------
// 1. Closed-set string unions (locked DB CHECK enums)
// -----------------------------------------------------------

/**
 * period_type — grain of a budget or actual line.
 * DB CHECK: ('month','quarter','year').
 * Budget rows default to 'quarter' (ADNOC plans quarterly).
 * Actual rows default to 'month' (ERP posts monthly).
 */
export type PeriodType = 'month' | 'quarter' | 'year';

/**
 * cost_category — accounting taxonomy for cost lines.
 * DB CHECK: ('day_rate','manpower','equipment','milestone','other').
 * Fixed statutory taxonomy for demo.
 */
export type CostCategory =
  | 'day_rate'
  | 'manpower'
  | 'equipment'
  | 'milestone'
  | 'other';

export const COST_CATEGORIES: ReadonlyArray<CostCategory> = [
  'day_rate',
  'manpower',
  'equipment',
  'milestone',
  'other',
] as const;

/**
 * contract_budget.source — provenance of a budget line.
 * DB CHECK: ('manual','demo_seed','import').
 */
export type BudgetSource = 'manual' | 'demo_seed' | 'import';

/**
 * contract_cost_actual.source — provenance of an actual-spend line.
 * DB CHECK: ('erp_feed','manual').
 */
export type ActualSource = 'erp_feed' | 'manual';

/**
 * Confidence level for year-end projection.
 */
export type ProjectionConfidence =
  | 'high'
  | 'medium'
  | 'low'
  | 'insufficient_data';

/**
 * Variance breach severity.
 */
export type VarianceSeverity = 'warning' | 'breach';

// -----------------------------------------------------------
// 2. ContractBudget entity (the PLAN)
// -----------------------------------------------------------

export interface ContractBudgetContractSummary {
  id: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
}

export interface ContractBudget {
  id: number;
  contractId: number;
  contract?: ContractBudgetContractSummary;
  periodType: PeriodType;
  periodLabel: string;
  fiscalYear: number;
  costCategory: CostCategory;
  /** MONEY — string to preserve NUMERIC(18,2) precision. */
  allocatedAmountAed: string;
  currency: string;
  notes: string | null;
  source: BudgetSource;
  createdAt: string;
  updatedAt: string;
  createdBy: number | null;
  updatedBy: number | null;
  isActive: boolean;
}

export interface ContractBudgetListItem {
  id: number;
  contractId: number;
  contractNumber: string;
  periodType: PeriodType;
  periodLabel: string;
  fiscalYear: number;
  costCategory: CostCategory;
  allocatedAmountAed: string;
  currency: string;
  notes: string | null;
  createdAt: string;
}

export interface ContractBudgetListResponse {
  data: ContractBudgetListItem[];
  pagination: PaginationMeta;
}

// -----------------------------------------------------------
// 3. ContractCostActual entity (actual-spend / ERP feed)
// -----------------------------------------------------------

export interface ContractCostActual {
  id: number;
  contractId: number;
  periodType: PeriodType;
  periodLabel: string;
  fiscalYear: number;
  costCategory: CostCategory;
  actualAmountAed: string;
  currency: string;
  source: ActualSource;
  referenceNo: string;
  recordedAt: string;
  notes: string | null;
  createdAt: string;
  updatedAt: string;
  createdBy: number | null;
  updatedBy: number | null;
  isActive: boolean;
}

export interface ContractCostActualListItem {
  id: number;
  contractId: number;
  periodType: PeriodType;
  periodLabel: string;
  fiscalYear: number;
  costCategory: CostCategory;
  actualAmountAed: string;
  currency: string;
  source: ActualSource;
  referenceNo: string;
  recordedAt: string;
  notes: string | null;
}

export interface ContractCostActualListResponse {
  data: ContractCostActualListItem[];
  pagination: PaginationMeta;
}

// -----------------------------------------------------------
// 4. Write DTOs
// -----------------------------------------------------------

export interface RecordCostActualDto {
  periodLabel: string;
  fiscalYear: number;
  costCategory: CostCategory;
  actualAmountAed: string | number;
  source?: ActualSource;
  referenceNo?: string;
  periodType?: PeriodType;
  notes?: string | null;
}

export type RecordCostActualResponse = ContractCostActual;

// -----------------------------------------------------------
// 5. Analytics JSONB shapes — fn_budget_burn_compute
// -----------------------------------------------------------

export interface BudgetBurnByCategory {
  costCategory: CostCategory;
  budgetAed: string;
  actualAed: string;
  varianceAed: string;
  variancePct: number | null;
  overThreshold: boolean;
}

export interface BudgetBurnByPeriod {
  periodLabel: string;
  fiscalYear: number;
  budgetAed: string;
  actualAed: string;
  varianceAed: string;
  variancePct: number | null;
  byCategory: BudgetBurnByCategory[];
}

export interface MonthlyActualRow {
  periodLabel: string;
  costCategory: CostCategory;
  actualAed: string;
}

export interface CumulativeBurnRow {
  periodLabel: string;
  cumulativeActualAed: string;
  cumulativeBudgetAed: string;
}

export interface BudgetBurnCompute {
  contractId: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  currency: string;
  totalBudgetAed: string;
  totalActualAed: string;
  totalVarianceAed: string;
  totalVariancePct: number;
  pctBudgetConsumed: number;
  remainingBudgetAed: string;
  byPeriod: BudgetBurnByPeriod[];
  monthlyActuals: MonthlyActualRow[];
  cumulativeBurn: CumulativeBurnRow[];
}

// -----------------------------------------------------------
// 6. Analytics JSONB shapes — fn_budget_variance_for_contract
// -----------------------------------------------------------

export interface VarianceBreach {
  periodLabel: string;
  costCategory: CostCategory;
  fiscalYear: number;
  budgetAed: string;
  actualAed: string;
  varianceAed: string;
  variancePct: number;
  severity: VarianceSeverity;
}

export interface CorrelatedClauseRef {
  clauseId: number;
  clauseType: 'cure_period';
  curePeriodDays: number | null;
  pageNo: number;
}

export interface LdClauseRef {
  clauseId: number;
  clauseType: 'liquidated_damages';
  ldRate: string | null;
  ldCap: string | null;
  pageNo: number;
}

export interface CorrelatedClauses {
  curePeriod: CorrelatedClauseRef[];
  liquidatedDamages: LdClauseRef[];
}

export interface BudgetVarianceResult {
  contractId: number;
  thresholdPct: number;
  thresholdSource: 'param' | 'system_setting' | 'default';
  breaches: VarianceBreach[];
  breachCount: number;
  maxVariancePct: number;
  correlatedClauses: CorrelatedClauses;
  cureNoticeEligible: boolean;
}

// -----------------------------------------------------------
// 7. Analytics JSONB shapes — fn_budget_year_end_projection
// -----------------------------------------------------------

export interface BudgetYearEndProjection {
  contractId: number;
  fiscalYear: number;
  asOfPeriod: string;
  monthsElapsed: number;
  monthsRemaining: number;
  actualToDateAed: string | null;
  runRatePerMonthAed: string | null;
  projectedYearEndAed: string | null;
  allocatedFyAed: string;
  projectedOverUnderAed: string | null;
  projectedOverUnderPct: number | null;
  isProjectedOverBudget: boolean | null;
  confidenceNote: ProjectionConfidence;
}

// -----------------------------------------------------------
// 8. Analytics JSONB shapes — fn_budget_burn_portfolio
// -----------------------------------------------------------

export interface PortfolioContractRow {
  contractId: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  counterpartyName: string | null;
  counterpartyNameAr: string | null;
  budgetAed: string;
  actualAed: string;
  varianceAed: string;
  variancePct: number;
  pctConsumed: number;
  projectedOverUnderAed: string;
  varianceFlag: boolean;
}

export interface PortfolioSummary {
  contractsWithBudget: number;
  totalBudgetAed: string;
  totalActualAed: string;
  totalVarianceAed: string;
  overBudgetCount: number;
  totalProjectedOverrunAed: string;
}

export interface BudgetBurnPortfolio {
  summary: PortfolioSummary;
  topOverBudget: PortfolioContractRow[];
  data: PortfolioContractRow[];
  pagination: PaginationMeta;
}

// -----------------------------------------------------------
// 9. Executive dashboard — additive budgetBurnSummary key
// -----------------------------------------------------------

export interface BudgetBurnSummaryTop3Row {
  contractId: number;
  contractNumber: string;
  titleEn: string;
  variancePct: number;
  varianceAed: string;
}

export interface BudgetBurnSummary {
  contractsWithBudget: number;
  overBudgetCount: number;
  totalProjectedOverrunAed: string;
  topOverBudget3: BudgetBurnSummaryTop3Row[];
}

// -----------------------------------------------------------
// 10. Cure-notice draft DTOs
// -----------------------------------------------------------

export interface DraftCureNoticeDto {
  thresholdPct?: number;
  focusPeriodLabel?: string;
}

export interface DraftCureNoticeResponse {
  draftId: number;
  correlationId: number;
  templateId: number;
  contractId: number;
  approvalStatus: string;
  cureNoticeEligible: boolean;
}

// -----------------------------------------------------------
// 11. Query-string shapes
// -----------------------------------------------------------

export interface BudgetListQuery {
  contractId?: number;
  fiscalYear?: number;
  costCategory?: CostCategory;
  page?: number;
  limit?: number;
}

export interface CostActualListQuery {
  contractId?: number;
  fiscalYear?: number;
  costCategory?: CostCategory;
  periodLabel?: string;
  page?: number;
  limit?: number;
}

export interface PortfolioQuery {
  fiscalYear?: number;
  minVariancePct?: number;
  costCategory?: CostCategory;
  page?: number;
  limit?: number;
}

// -----------------------------------------------------------
// 12. Response envelope aliases
// -----------------------------------------------------------

export type BudgetBurnComputeEnvelope = ApiResponse<BudgetBurnCompute>;
export type BudgetVarianceEnvelope = ApiResponse<BudgetVarianceResult>;
export type BudgetYearEndProjectionEnvelope = ApiResponse<BudgetYearEndProjection>;
export type BudgetBurnPortfolioEnvelope = ApiResponse<BudgetBurnPortfolio>;
export type ContractBudgetListEnvelope = ApiResponse<ContractBudgetListResponse>;
export type ContractBudgetDetailEnvelope = ApiResponse<ContractBudget>;
export type CostActualListEnvelope = ApiResponse<ContractCostActualListResponse>;
export type RecordCostActualEnvelope = ApiResponse<RecordCostActualResponse>;
export type DraftCureNoticeEnvelope = ApiResponse<DraftCureNoticeResponse>;
