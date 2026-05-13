/**
 * M14 / CR-F — 5-Dim Risk Scoring + MaR + AVaR
 * TypeScript type definitions for the BE layer.
 *
 * Mirrors Agent 5 types.ts shapes. All BIGINT fields serialized as string
 * per project convention. Sensitive fields (contributingCorrelations,
 * explanation, marValue) are never logged — Pino redact wires these
 * at logger.util.ts extension.
 */

// ============================================================
// Permission constants
// ============================================================

/** CR-F permission codes seeded by migration 175. */
export const CR_F_PERMISSION_SCORE_READ = 'score.read' as const;
export const CR_F_PERMISSION_SCORE_WEIGHTS_MANAGE = 'score.weights.manage' as const;
export const CR_F_PERMISSION_RISK_ACKNOWLEDGE = 'risk.acknowledge' as const;

/** ADNOC singleton tenant UUID — used for RLS GUC context. */
export const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001' as const;

/** System actor sentinel (actor_id = 0 → NULL coercion in fn_risk_score_compute per S2-20). */
export const SYSTEM_ACTOR_ID = 0 as const;

// ============================================================
// Valid enum values matching DB CHECK constraints
// ============================================================

export const RISK_SCORE_TRIGGERED_BY_VALUES = [
  'signal',
  'clause_change',
  'weight_change',
  'scheduled',
  'manual',
  'bootstrap',
] as const;

export type RiskScoreTriggeredBy = typeof RISK_SCORE_TRIGGERED_BY_VALUES[number];

export const AVAR_GROUP_BY_VALUES = [
  'business_unit',
  'counterparty_id',
  'counterparty_chain',
  'geography',
  'risk_kind',
] as const;

export type AvarGroupBy = typeof AVAR_GROUP_BY_VALUES[number];

/** Allowed windowDays values for fn_risk_score_history (validated by DB ERRCODE 22023). */
export const HISTORY_WINDOW_DAYS_ALLOWED = [30, 90, 180] as const;

// ============================================================
// Dimension breakdown and explanation shapes
// ============================================================

/** One dimension's breakdown within explanation JSONB. */
export interface RiskScoreDimensionBreakdown {
  score: number;
  probability: number;
  impact: number;
  reasons: string[];
}

/** Scoring weights snapshot at compute time. */
export interface WeightsAtCalculation {
  legal: number;
  financial: number;
  operational: number;
  reputational: number;
  compliance: number;
}

/** MaR formula breakdown stored in explanation for audit traceability. */
export interface MarFormulaBreakdown {
  contractValue: string | null;
  exposureFraction: number;
  probability: null;
  impactMultiplier: null;
  marValue: string | null;
}

/** SENSITIVE — risk_score.explanation JSONB shape. Never log. */
export interface RiskScoreExplanation {
  dimensions: {
    legal: RiskScoreDimensionBreakdown;
    financial: RiskScoreDimensionBreakdown;
    operational: RiskScoreDimensionBreakdown;
    reputational: RiskScoreDimensionBreakdown;
    compliance: RiskScoreDimensionBreakdown;
  };
  marFormula: MarFormulaBreakdown;
  weightsAtCalculation: WeightsAtCalculation;
  contributingClauses: string[];
}

/** SENSITIVE — single entry in risk_score.contributing_correlations. Never log. */
export interface ContributingCorrelation {
  correlationId: string;
  ruleId: string;
  probability: number;
  impactMultiplier: number;
  marContribution: string | null;
  dimensionsAffected: string[];
}

// ============================================================
// fn_risk_score_explain return shape
// ============================================================

/** Hydrated correlation with signal + rule + clause details. */
export interface HydratedContributingCorrelation extends ContributingCorrelation {
  ruleVersionHash: string | null;
  confidence: number;
  matchReason: string | null;
  status: string;
  sourceReliability: number;
  signal: {
    id: string;
    titleEn: string | null;
    titleAr: string | null;
    signalKind: string | null;
    occurredAt: string | null;
  };
  matchedClause: {
    id: string;
    clauseTypeV2: string | null;
    snippet: string | null;
  } | null;
}

/**
 * Return shape of fn_risk_score_explain(p_contract_id BIGINT, p_actor_id BIGINT).
 * Source: db-design.md §3.1. Powers GET /api/v1/contracts/:id/risk-score.
 */
export interface RiskScoreExplainResponse {
  riskScoreId: string;
  contractId: string;
  healthScore: number;
  dimensions: {
    legal: RiskScoreDimensionBreakdown;
    financial: RiskScoreDimensionBreakdown;
    operational: RiskScoreDimensionBreakdown;
    reputational: RiskScoreDimensionBreakdown;
    compliance: RiskScoreDimensionBreakdown;
  };
  marFormula: MarFormulaBreakdown;
  marValue: string | null;
  marCurrency: 'AED';
  weightsVersion: string;
  weightsAtCalculation: WeightsAtCalculation;
  contributingCorrelations: HydratedContributingCorrelation[];
  calculatedAt: string;
  triggeredBy: RiskScoreTriggeredBy;
}

// ============================================================
// fn_risk_score_history return shape
// ============================================================

/** Single snapshot in the history list. */
export interface RiskScoreHistorySnapshot {
  riskScoreId: string;
  calculatedAt: string;
  healthScore: number;
  dimLegal: number;
  dimFinancial: number;
  dimOperational: number;
  dimReputational: number;
  dimCompliance: number;
  marValue: string | null;
  marCurrency: 'AED';
  triggeredBy: RiskScoreTriggeredBy;
  weightsVersion: string;
}

/**
 * Return shape of fn_risk_score_history(p_contract_id BIGINT, p_window_days INTEGER, p_actor_id BIGINT).
 * Powers GET /api/v1/contracts/:id/risk-score/history.
 */
export interface RiskScoreHistoryResponse {
  contractId: string;
  windowDays: number;
  snapshots: RiskScoreHistorySnapshot[];
  count: number;
}

// ============================================================
// fn_avar_aggregate return shape
// ============================================================

/** Single breakdown bucket in the AVaR aggregation. S2-24 invariant: derived from inner CTE SUM. */
export interface AvarBreakdownBucket {
  key: string;
  label: string;
  avar: string | null;
  contractCount: number;
  pctOfTotal: number | null;
}

/** Delta vs prior equivalent window. */
export interface AvarDeltaVsPriorWindow {
  priorAvar: string;
  deltaAed: string;
  deltaPct: number | null;
}

/**
 * Return shape of fn_avar_aggregate(p_filters JSONB, p_window_days INTEGER, p_actor_id BIGINT).
 * Powers GET /api/v1/risk/avar.
 */
export interface AvarAggregateResponse {
  totalAvar: string;
  currency: 'AED';
  contractCount: number;
  windowDays: number;
  groupBy: AvarGroupBy;
  noValueCount: number;
  breakdown: AvarBreakdownBucket[];
  deltaVsPriorWindow: AvarDeltaVsPriorWindow;
}

// ============================================================
// fn_scoring_weights_get return shape
// ============================================================

/** Current scoring weights config. */
export interface ScoringWeightsCurrent {
  legal: number;
  financial: number;
  operational: number;
  reputational: number;
  compliance: number;
  version: string;
  updatedAt: string | null;
  updatedBy: string | null;
}

/** Single entry in the scoring weights version history. */
export interface ScoringWeightsHistoryEntry {
  version: string;
  changedAt: string;
  changedById: string | null;
}

/**
 * Return shape of fn_scoring_weights_get(p_actor_id BIGINT).
 * Powers GET /api/v1/admin/scoring-weights.
 */
export interface ScoringWeightsGetResponse {
  current: ScoringWeightsCurrent;
  history: ScoringWeightsHistoryEntry[];
  exposureFractionDefaults: Record<string, number>;
  impactMultipliers: Record<string, number>;
}

// ============================================================
// fn_scoring_weights_set request + return shapes
// ============================================================

/** Request body for PATCH /api/v1/admin/scoring-weights. All 5 dims required. Sum = 1.0 ± 0.001. */
export interface ScoringWeightsUpdateRequest {
  legal: number;
  financial: number;
  operational: number;
  reputational: number;
  compliance: number;
}

/**
 * Return shape of fn_scoring_weights_set(p_weights JSONB, p_actor_id BIGINT).
 * Powers PATCH /api/v1/admin/scoring-weights response.
 */
export interface ScoringWeightsSetResponse {
  newVersion: string;
  weightsApplied: ScoringWeightsCurrent;
  totalSum: number;
}

// ============================================================
// fn_score_recompute_for_weight_change return shape
// ============================================================

/**
 * Return shape of fn_score_recompute_for_weight_change(p_actor_id BIGINT).
 * Powers POST /api/v1/admin/scoring-weights/recompute-all.
 */
export interface ScoreRecomputeForWeightChangeResult {
  weightsVersion: string;
  totalContractsTargeted: number;
  recomputedCount: number;
  failedContractIds: string[];
  elapsedMs: number;
}

// ============================================================
// fn_score_recompute_for_signal return shape (worker internal)
// ============================================================

/**
 * Return shape of fn_score_recompute_for_signal(p_signal_id BIGINT, p_actor_id BIGINT).
 * Used internally by score-recompute.worker.ts — not exposed as HTTP endpoint.
 */
export interface ScoreRecomputeForSignalResult {
  signalId: string;
  affectedContractCount: number;
  recomputedRiskScoreIds: string[];
  deduplicatedContractCount: number;
}

// ============================================================
// PG NOTIFY payload (score-recompute.worker.ts)
// ============================================================

/**
 * Shape of JSON payload emitted by fn_rule_evaluate (migration 172) on
 * pg_notify('correlation_inserted', ...).
 * Consumed by score-recompute.worker.ts LISTEN handler.
 *
 * QA Stage 3 W1 note: signalId is typed as number (JSON numeric) rather
 * than string. In v1 signal IDs are well below 2^53 so JSON precision
 * is not at risk. The fn_rule_evaluate body emits a numeric JSON value —
 * we document the acceptable-risk decision here rather than requiring a
 * DB migration to stringify it.
 */
export interface CorrelationInsertedNotifyPayload {
  /** UUID — used to set app.current_tenant_id GUC before fn_ call. */
  tenantId: string;
  /** BIGINT as JSON number. v1 signal counts well below 2^53 — acceptable-risk per QA Stage 3 W1. */
  signalId: number;
  /** Count of correlations inserted (always > 0 — fn only emits when > 0). */
  inserted: number;
}
