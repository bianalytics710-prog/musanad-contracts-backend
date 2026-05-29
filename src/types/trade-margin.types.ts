// ============================================================
// CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
// TypeScript Type Definitions
// Derived from: db-design.md §C, §D (Agent 4 output)
// Do not edit manually — regenerate via Agent 5 if DB design changes.
// ============================================================

import type { ApiResponse, PaginationMeta } from './api.types';

// -----------------------------------------------------------
// 1. Closed-set string unions (locked DB CHECK enums)
// -----------------------------------------------------------

/**
 * TradeSide — which side of the trade.
 * DB CHECK: ('sell','buy') on trade_position.side + margin_snapshot.side.
 */
export type TradeSide = 'sell' | 'buy';

/**
 * TradeGrade — crude grade.
 * DB CHECK: ('murban','west_african_x','brent','dubai','wti','other').
 */
export type TradeGrade =
  | 'murban'
  | 'west_african_x'
  | 'brent'
  | 'dubai'
  | 'wti'
  | 'other';

/**
 * BenchmarkCode — identifies the price benchmark.
 * DB CHECK on price_benchmark.benchmark_code.
 */
export type BenchmarkCode =
  | 'murban_osp'
  | 'brent'
  | 'dubai'
  | 'wti'
  | 'west_african_x'
  | 'usd_aed';

/**
 * BenchmarkUnit — unit for price_benchmark.price_value.
 * DB CHECK: ('usd_per_bbl','aed_per_usd').
 */
export type BenchmarkUnit = 'usd_per_bbl' | 'aed_per_usd';

/**
 * BenchmarkPeriodGrain — time grain of the benchmark observation.
 * DB CHECK: ('monthly','daily','spot').
 */
export type BenchmarkPeriodGrain = 'monthly' | 'daily' | 'spot';

/**
 * BenchmarkSource — provenance of the price observation.
 * DB CHECK: ('osp_official','market','mock').
 */
export type BenchmarkSource = 'osp_official' | 'market' | 'mock';

/**
 * PricingBasis — the benchmark driving seller revenue resolution.
 * DB CHECK on trade_position.pricing_basis.
 */
export type PricingBasis = 'murban_osp' | 'brent' | 'dubai' | 'wti' | 'spot';

/**
 * TermOrSpot — deal tenor.
 * DB CHECK: ('term','spot').
 */
export type TermOrSpot = 'term' | 'spot';

/**
 * TradePositionStatus — lifecycle state.
 * DB CHECK: ('open','priced','closed').
 */
export type TradePositionStatus = 'open' | 'priced' | 'closed';

/**
 * ComponentType — type of a trade_cost_component row.
 */
export type ComponentType =
  | 'lifting'
  | 'transport_charter'
  | 'insurance'
  | 'hedge'
  | 'crude_purchase'
  | 'refining'
  | 'transport'
  | 'storage'
  | 'downstream_sale';

/**
 * MarginTriggeredBy — what triggered a margin_snapshot computation.
 * DB CHECK: ('manual','price_change','worker','bootstrap').
 */
export type MarginTriggeredBy =
  | 'manual'
  | 'price_change'
  | 'worker'
  | 'bootstrap';

/**
 * MarginRecommendation — derived recommendation stored on margin_snapshot.
 * DB CHECK: ('buy','hold','sell','review') or NULL.
 */
export type MarginRecommendation = 'buy' | 'hold' | 'sell' | 'review';

/**
 * TradeDataClassification — data maturity label on all CR-O tables.
 * DB CHECK: ('demo','pilot','production').
 */
export type TradeDataClassification = 'demo' | 'pilot' | 'production';

// -----------------------------------------------------------
// 2. PriceBenchmark entity
// -----------------------------------------------------------

export interface PriceBenchmark {
  id: number;
  benchmarkCode: BenchmarkCode;
  priceDate: string;
  /** MONEY — string to preserve NUMERIC(12,4) precision. */
  priceValue: string;
  unit: BenchmarkUnit;
  periodGrain: BenchmarkPeriodGrain;
  source: BenchmarkSource;
  notes: string | null;
  createdAt: string;
  updatedAt: string;
  createdBy: number | null;
  updatedBy: number | null;
  isActive: boolean;
}

export interface PriceBenchmarkListItem {
  id: number;
  benchmarkCode: BenchmarkCode;
  priceDate: string;
  /** MONEY — string. */
  priceValue: string;
  unit: BenchmarkUnit;
  periodGrain: BenchmarkPeriodGrain;
  source: BenchmarkSource;
  notes: string | null;
}

export interface PriceBenchmarkListResponse {
  data: PriceBenchmarkListItem[];
  pagination: PaginationMeta;
}

// -----------------------------------------------------------
// 3. Write DTOs for price benchmark
// -----------------------------------------------------------

export interface RecordPriceBenchmarkDto {
  benchmarkCode: BenchmarkCode;
  priceDate: string;
  /** Non-negative. String accepted to avoid float precision loss. */
  priceValue: string | number;
  unit: BenchmarkUnit;
  periodGrain?: BenchmarkPeriodGrain;
  source?: BenchmarkSource;
  notes?: string | null;
}

export interface RecomputePriceBenchmarkDto {
  benchmarkCode: BenchmarkCode;
  /** Non-negative. String to avoid float precision loss. */
  newPrice: string | number;
  priceDate?: string;
}

// -----------------------------------------------------------
// 4. TradePosition entity
// -----------------------------------------------------------

export interface CounterpartySummary {
  id: number;
  nameEn: string;
  nameAr: string | null;
}

export interface LinkedContractSummary {
  id: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
}

export interface CostComponentItem {
  id: number;
  componentType: ComponentType;
  /** MONEY — string (NUMERIC(12,4) as text). */
  amountUsdPerBbl: string;
  isRevenue: boolean;
  notes: string | null;
}

export interface LatestMarginBlock {
  /** MONEY — string. */
  marginPerBbl: string;
  /** MONEY — string. */
  totalMarginUsd: string;
  /** MONEY — string (AED as ::text). */
  totalMarginAed: string;
  recommendation: MarginRecommendation | null;
  latestComputedAt: string;
}

export interface TradePosition {
  id: number;
  positionRef: string;
  side: TradeSide;
  grade: TradeGrade;
  counterparty: CounterpartySummary;
  internalEntity: CounterpartySummary | null;
  /** NUMERIC(18,2) → string. */
  volumeBbl: string;
  pricingBasis: PricingBasis;
  deliveryMonth: string;
  termOrSpot: TermOrSpot;
  linkedContract: LinkedContractSummary | null;
  status: TradePositionStatus;
  notes: string | null;
  costComponents: CostComponentItem[];
  /** null when no margin_snapshot has been computed yet. */
  latestMargin: LatestMarginBlock | null;
  dataClassification: TradeDataClassification;
  createdAt: string;
  updatedAt: string;
  createdBy: number | null;
  updatedBy: number | null;
  isActive: boolean;
}

export interface TradePositionListItem {
  id: number;
  positionRef: string;
  side: TradeSide;
  grade: TradeGrade;
  counterparty: CounterpartySummary;
  /** MONEY — string. */
  volumeBbl: string;
  pricingBasis: PricingBasis;
  deliveryMonth: string;
  termOrSpot: TermOrSpot;
  status: TradePositionStatus;
  /** MONEY — string | null (null before first compute). */
  marginPerBbl: string | null;
  /** MONEY — string | null. */
  totalMarginUsd: string | null;
  /** MONEY — string | null. */
  totalMarginAed: string | null;
  recommendation: MarginRecommendation | null;
  latestComputedAt: string | null;
}

export interface TradePositionListResponse {
  data: TradePositionListItem[];
  pagination: PaginationMeta;
}

// -----------------------------------------------------------
// 5. fn_margin_compute return shape (§D-1)
// -----------------------------------------------------------

export interface MarginRevenueItem {
  label: string;
  type: 'benchmark' | 'component';
  /** MONEY — string. */
  usdPerBbl: string;
}

export interface MarginCostItem {
  componentType: ComponentType;
  /** MONEY — string. */
  usdPerBbl: string;
}

export interface MarginBreakdownFx {
  code: string;
  /** MONEY — string. */
  rate: string;
}

export interface MarginBreakdown {
  revenue: MarginRevenueItem[];
  costs: MarginCostItem[];
  /** MONEY — string. */
  totalCostPerBbl: string;
  /** MONEY — string. */
  marginPerBbl: string;
  fx: MarginBreakdownFx;
}

export interface MarginComputeResult {
  tradePositionId: number;
  positionRef: string;
  side: TradeSide;
  grade: TradeGrade;
  /** MONEY — string (NUMERIC(18,2) as text). */
  volumeBbl: string;
  benchmarkCodeUsed: string | null;
  /** MONEY — string | null (null for buyer). */
  benchmarkPriceUsed: string | null;
  /** MONEY — string. */
  revenuePerBbl: string;
  /** MONEY — string. */
  costPerBbl: string;
  /** MONEY — string. May be negative. */
  marginPerBbl: string;
  /** MONEY — string (NUMERIC(18,2) as text). */
  totalMarginUsd: string;
  /** MONEY — string (NUMERIC(12,4) as text). */
  usdAedRate: string;
  /** MONEY — string (NUMERIC(18,2) as text). */
  totalMarginAed: string;
  recommendation: MarginRecommendation;
  breakdown: MarginBreakdown;
  computedAt: string;
  triggeredBy: MarginTriggeredBy;
}

// -----------------------------------------------------------
// 6. fn_margin_recompute_for_price_change return shape (§D-2)
// -----------------------------------------------------------

export interface MarginRecomputeResult {
  benchmarkCode: string;
  /** MONEY — string (NUMERIC(12,4) as text). */
  newPrice: string;
  priceDate: string;
  positionsRecomputed: number;
  deduplicatedCount: number;
  /** MONEY — string. */
  priorAggregateMarginAed: string;
  /** MONEY — string. */
  newAggregateMarginAed: string;
  /** MONEY — string. Negative = margin compression. */
  deltaAed: string;
  /** MONEY — string. Negative = margin compression. */
  deltaUsd: string;
  recomputedPositionIds: number[];
}

// -----------------------------------------------------------
// 7. fn_margin_aggregate return shape (§D-3)
// -----------------------------------------------------------

export interface MarginAggregateBucket {
  key: string;
  label: string;
  /** MONEY — string. */
  marginAed: string;
  /** MONEY — string. */
  marginUsd: string;
  positionCount: number;
  pctOfTotal: number;
}

export interface MarginAggregateResult {
  /** MONEY — string. */
  totalMarginAed: string;
  /** MONEY — string. */
  totalMarginUsd: string;
  currency: string;
  positionCount: number;
  groupBy: 'counterparty' | 'quarter' | 'side';
  breakdown: MarginAggregateBucket[];
}

// -----------------------------------------------------------
// 8. fn_margin_snapshot_history return shape (§D-8)
// -----------------------------------------------------------

export interface MarginSnapshotHistoryItem {
  marginSnapshotId: number;
  computedAt: string;
  /** MONEY — string | null (null for buyer side). */
  benchmarkPriceUsed: string | null;
  /** MONEY — string. */
  revenuePerBbl: string;
  /** MONEY — string. */
  costPerBbl: string;
  /** MONEY — string. */
  marginPerBbl: string;
  /** MONEY — string. */
  totalMarginUsd: string;
  /** MONEY — string (AED as ::text). */
  totalMarginAed: string;
  triggeredBy: MarginTriggeredBy;
}

export interface MarginSnapshotHistoryResult {
  tradePositionId: number;
  count: number;
  /** ASC computed_at order — index 0 is oldest. */
  snapshots: MarginSnapshotHistoryItem[];
}

// -----------------------------------------------------------
// 9. Executive dashboard additive key (§D-11)
// -----------------------------------------------------------

export interface TradeMarginSummaryBySideEntry {
  positionCount: number;
  /** MONEY — string. */
  marginAed: string;
}

export interface TradeMarginSummaryBySide {
  sell: TradeMarginSummaryBySideEntry;
  buy: TradeMarginSummaryBySideEntry;
}

export interface TradeMarginSummaryRecentChange {
  benchmarkCode: string;
  /** MONEY — string. Negative = margin compression. */
  deltaAed: string;
  /** MONEY — string. */
  deltaUsd: string;
  asOf: string;
}

export interface TradeMarginSummaryTopRow {
  tradePositionId: number;
  positionRef: string;
  side: TradeSide;
  counterpartyName: string;
  /** MONEY — string. */
  totalMarginAed: string;
}

export interface TradeMarginSummary {
  openPositionCount: number;
  /** MONEY — string. */
  totalMarginAed: string;
  /** MONEY — string. */
  totalMarginUsd: string;
  bySide: TradeMarginSummaryBySide;
  recentMarginChange: TradeMarginSummaryRecentChange | null;
  topPositionsByMargin3: TradeMarginSummaryTopRow[];
}

// -----------------------------------------------------------
// 10. Query-string shapes
// -----------------------------------------------------------

export interface TradePositionListQuery {
  side?: TradeSide;
  grade?: TradeGrade;
  status?: TradePositionStatus;
  search?: string;
  page?: number;
  limit?: number;
}

export interface PriceBenchmarkListQuery {
  benchmarkCode?: BenchmarkCode;
  from?: string;
  to?: string;
  page?: number;
  limit?: number;
}

export interface MarginAggregateQuery {
  groupBy?: 'counterparty' | 'quarter' | 'side';
}

// -----------------------------------------------------------
// 11. Response envelope aliases (ApiResponse<T> wrappers)
// -----------------------------------------------------------

export type MarginComputeEnvelope = ApiResponse<MarginComputeResult>;
export type MarginRecomputeEnvelope = ApiResponse<MarginRecomputeResult>;
export type MarginAggregateEnvelope = ApiResponse<MarginAggregateResult>;
export type MarginSnapshotHistoryEnvelope = ApiResponse<MarginSnapshotHistoryResult>;
export type TradePositionListEnvelope = ApiResponse<TradePositionListResponse>;
export type TradePositionDetailEnvelope = ApiResponse<TradePosition>;
export type PriceBenchmarkListEnvelope = ApiResponse<PriceBenchmarkListResponse>;
export type RecordPriceBenchmarkEnvelope = ApiResponse<PriceBenchmark>;
