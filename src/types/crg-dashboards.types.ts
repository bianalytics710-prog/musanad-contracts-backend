/**
 * M15 / CR-G — Executive Decision Support Evolution + 4 Persona Dashboards
 *              + AI Risk Assistant — Backend TypeScript Type Definitions
 *
 * Mirrored from workspace types.ts (Agent 5 canonical source).
 * Self-contained for tsc — no workspace imports.
 *
 * BIGINT ids are serialized as string per project convention.
 * NUMERIC monetary fields are serialized as string.
 *
 * QA advisories applied:
 *   W1: dim_* fields in SupplierScorecardRow → camelCase (dimLegal, etc.)
 *   W2: vendorFinancialHealthSummary kind filter locked to kind='news' + signal_kind_subtype
 *   W4: kpiPrev blocks typed as optional with same shape
 *   W5: sanctions_chain optional fields used (chainPath: string[] | null)
 *   W6: subContractorChainView uses FOR-LOOP/fn_party_chain_summary shape
 *   W-S3-1: windowDays + asOf envelope keys present on all 4 new dashboard responses
 */

// ============================================================
// 1. fn_dashboard_executive EXTEND — 3 new top-level keys (§3.1)
// ============================================================

/**
 * ExecutiveDashboardCrgAdditions — 3 new top-level keys appended to the
 * existing R-EX fn_dashboard_executive response.
 * Decision A1 (locked): valueAtRisk NOT in this payload.
 */
export interface ExecutiveDashboardCrgAdditions {
  whatChangedToday: WhatChangedTodayRow[];
  recommendedActions: RecommendedActionRow[];
  clausesTriggered: ClausesTriggeredPayload;
}

/** One entry in whatChangedToday array. BIGINT ids as string. */
export interface WhatChangedTodayRow {
  correlationId: string;
  contractId: string;
  ruleId: string;
  headline: string;
  scenario?: string | null;
  marAed: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  occurredAt: string;
}

/** One entry in recommendedActions array. BIGINT ids as string. */
export interface RecommendedActionRow {
  correlationId: string;
  contractId: string;
  ruleId?: string;
  action: string | null;
  /** produce_yaml.alert.assigned_roles — PLURAL ARRAY per M13-projection lock. */
  assignedRoles: string[];
  slaHours: number | null;
  marAed: string;
}

/** Wrapper for 7d and 30d sub-blocks. */
export interface ClausesTriggeredPayload {
  last7d: ClausesTriggeredRow[];
  last30d: ClausesTriggeredRow[];
}

/** One entry in clausesTriggered.last7d / .last30d arrays. */
export interface ClausesTriggeredRow {
  clauseFamily: string;
  clauseType: string;
  count: number;
  contractsAffected: number;
  totalMarAed: string;
}

// ============================================================
// 2. fn_dashboard_operations — response shape (§3.2)
// ============================================================

/** Full JSONB payload from fn_dashboard_operations. */
export interface OperationsDashboardResponse {
  windowDays: number;
  asOf: string;
  kpi: OperationsKpi;
  kpiPrev?: OperationsKpi;
  slaBreachesList: SlaBreachRow[];
  deliveryDelayTracker: DeliveryDelayRow[];
  penaltyExposureByContract: PenaltyExposureRow[];
  opsEventsFeed: OpsEventRow[];
  vendorScorecards: VendorScorecardRow[];
}

export interface OperationsKpi {
  openSlaBreaches: number;
  openSlaBreachesMarAed: string;
  deliveryDelaysCount: number;
  contractPenaltyExposureAed: string;
  vendorsWithBreaches: number;
}

export interface SlaBreachRow {
  contractId: string;
  contractNumber: string;
  contractTitle: string;
  counterpartyName: string;
  breachKind: string;
  signalId: string;
  occurredAt: string;
  severity: string;
  marAed: string;
}

export interface DeliveryDelayRow {
  contractId: string;
  contractNumber: string;
  counterpartyName: string;
  lastDelayedMilestone: string | null;
  delayDays: number | null;
  signalCount180d: number;
  severity: string;
}

export interface PenaltyExposureRow {
  contractId: string;
  contractNumber: string;
  counterpartyName: string;
  penaltyClauseSummary: string;
  exposureAed: string;
}

export interface OpsEventRow {
  eventType: string;
  contractId: string;
  counterpartyName: string;
  headline: string;
  occurredAt: string;
  severity: string;
  sourceRef: string | null;
}

export interface VendorScorecardRow {
  counterpartyId: string;
  counterpartyName: string;
  slaBreachCount180d: number;
  deliveryDelayCount180d: number;
  riskScore: number;
  performanceTier: 'high' | 'medium' | 'low';
}

// ============================================================
// 3. fn_dashboard_finance_treasury — response shape (§3.3)
// ============================================================

/** Full JSONB payload from fn_dashboard_finance_treasury. */
export interface FinanceTreasuryDashboardResponse {
  windowDays: number;
  asOf: string;
  kpi: FinanceTreasuryKpi;
  kpiPrev?: FinanceTreasuryKpi;
  fxVolatilityTile: FxVolatilityTile;
  priceReviewTriggerQueue: PriceReviewRow[];
  paymentDelayRegister: PaymentDelayRow[];
  currencyExposureBreakdown: CurrencyExposureRow[];
}

export interface FinanceTreasuryKpi {
  totalExposureAed: string;
  fxExposureNonAedAed: string;
  priceReviewTriggeredCount: number;
  paymentDelaysCount: number;
  paymentDelaysAed: string;
}

export interface FxVolatilityTile {
  aedPegStatus: 'stable' | 'deviation';
  pegDeviationBps: number | null;
  lastCheckedAt: string;
  nonAedContractCount: number;
  nonAedContractValueAed: string;
}

export interface PriceReviewRow {
  correlationId: string;
  contractId: string;
  contractNumber: string;
  counterpartyName: string;
  triggerSignalRef: string | null;
  triggerHeadline: string;
  indexName: string | null;
  indexMoveBps: number | null;
  marAed: string;
  recommendedAction: string | null;
  occurredAt: string;
}

export interface PaymentDelayRow {
  correlationId: string;
  contractId: string;
  contractNumber: string;
  counterpartyName: string;
  signalId: string;
  invoiceRef: string | null;
  daysOverdue: number | null;
  amountAed: string;
  severity: string;
}

export interface CurrencyExposureRow {
  currency: string;
  contractCount: number;
  aggregateValueOriginal: string;
  aggregateValueAed: string;
  percentOfTotal: number;
}

// ============================================================
// 4. fn_dashboard_compliance_esg — response shape (§3.4)
// ============================================================

/** Full JSONB payload from fn_dashboard_compliance_esg. */
export interface ComplianceEsgDashboardResponse {
  windowDays: number;
  asOf: string;
  kpi: ComplianceEsgKpi;
  kpiPrev?: ComplianceEsgKpi;
  sanctionsExposureList: SanctionsExposureRow[];
  auditRightsTracker: AuditRightsRow[];
  subContractorChainView: SubContractorChainRow[];
  regulatoryUpdatesMonitor: RegulatoryUpdateRow[];
  esgCorrelations: EsgCorrelationRow[];
}

export interface ComplianceEsgKpi {
  sanctionsExposureDirectCount: number;
  sanctionsExposureChainCount: number;
  auditRightsExpiringCount: number;
  openRegulatoryUpdatesCount: number;
  openEsgCorrelationsCount: number;
}

export interface SanctionsExposureRow {
  contractId: string;
  contractNumber: string;
  counterpartyId: string;
  counterpartyName: string;
  sanctionsStatus: string;
  exposureKind: 'direct' | 'chain';
  chainPath: string[] | null;
  chainTruncated: boolean;
  marAed: string;
}

export interface AuditRightsRow {
  contractId: string;
  contractNumber: string;
  counterpartyName: string;
  auditClauseType: string;
  expiresOnIso: string;
  daysToExpiry: number;
  severity: 'high' | 'medium' | 'low';
}

export interface SubContractorChainRow {
  chainRootCounterpartyId: string;
  chainRootName: string;
  depthReached: number;
  sanctionedNodesCount: number;
  affectedContractsCount: number;
  chainTruncated: boolean;
}

export interface RegulatoryUpdateRow {
  regulatoryUpdateId: string;
  regulatorName: string;
  headline: string;
  severity: string;
  occurredAt: string;
  affectedContractsCount: number;
}

export interface EsgCorrelationRow {
  correlationId: string;
  headline: string;
  contractId: string;
  counterpartyName: string;
  marAed: string;
  occurredAt: string;
  severity: string;
}

// ============================================================
// 5. fn_dashboard_procurement_supplier_risk — response shape (§3.5)
// ============================================================

/** Full JSONB payload from fn_dashboard_procurement_supplier_risk. */
export interface ProcurementSupplierRiskDashboardResponse {
  windowDays: number;
  asOf: string;
  kpi: ProcurementKpi;
  kpiPrev?: ProcurementKpi;
  supplierRiskScorecard: SupplierScorecardRow[];
  icvComplianceTracker: IcvComplianceRow[];
  backupSupplierSuggestions: BackupSupplierGroup[];
  vendorFinancialHealthSummary: VendorFinancialHealthRow[];
}

export interface ProcurementKpi {
  totalSupplierCount: number;
  supplierBreachesCount: number;
  icvNonCompliantCount: number;
  supplierFinancialDistressCount: number;
  avgSupplierRiskScore: number | null;
}

/** W1: dim_* fields use camelCase per QA advisory. */
export interface SupplierScorecardRow {
  counterpartyId: string;
  counterpartyName: string;
  partyType: string;
  compositeRiskScore: number | null;
  dimLegal: number | null;
  dimFinancial: number | null;
  dimOperational: number | null;
  dimReputational: number | null;
  dimCompliance: number | null;
  slaBreachCount180d: number;
  activeContractCount: number;
  totalContractValueAed: string;
  riskTier: 'high' | 'medium' | 'low';
}

export interface IcvComplianceRow {
  counterpartyId: string;
  counterpartyName: string;
  icvStatus: string | null;
  icvPct: number | null;
  icvLastChecked: string | null;
  activeContractCount: number;
  contractValueAed: string;
}

export interface BackupSupplierGroup {
  primaryCounterpartyId: string;
  primaryName: string;
  primaryRiskScore: number | null;
  category: string;
  suggestedAlternatives: BackupSupplierAlternative[];
}

export interface BackupSupplierAlternative {
  counterpartyId: string;
  counterpartyName: string;
  riskScore: number | null;
  cleanStatus: string;
}

/** W2: kind='news' AND signal_kind_subtype IN ('financial_distress','downgrade','default'). */
export interface VendorFinancialHealthRow {
  counterpartyId: string;
  counterpartyName: string;
  signalKind: string;
  signalHeadline: string;
  occurredAt: string;
  severity: string;
  sourceRef: string | null;
}

// ============================================================
// 6. CR-G permission code constants
// ============================================================

export const CR_G_PERMISSION_CODES = [
  'insights.operations',
  'insights.finance_treasury',
  'insights.compliance_esg',
  'insights.procurement_supplier_risk',
  'ai.invoke.risk_assistant',
] as const;

export type CrgPermissionCode = typeof CR_G_PERMISSION_CODES[number];
