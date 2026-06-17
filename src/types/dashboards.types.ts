// ============================================================
// M6 — Dashboards & Reporting — TypeScript Type Definitions (BE)
// Mirrors workspace/current-module/types.ts (canonical Agent 5 source).
// Local copy here so the backend repo is self-contained for tsc.
//
// Cross-module touchpoints:
// - Reuses ApiResponse (M0 — api.types) — conceptual envelope only;
//   M6 controllers pass through the fn_ JSONB verbatim (matches M5
//   regulatory pass-through pattern).
// - Reuses Contract / ContractListItem (M1a — contracts.types) READ-shape
//   only — DashboardContractRow is a NEW lighter 7-column projection;
//   M1a Contract is UNCHANGED in M6.
// - Reuses RegulatoryUpdate / RegulatorRef (M5 — regulatory.types) READ-shape
//   only — DashboardRegulatoryUpdateRow is a NEW lighter projection;
//   M5 RegulatoryUpdate is UNCHANGED.
// - Reuses AiInsight payload / AiCostReport (M4 — ai.types) — referenced
//   only by internal fn_-to-fn_ calls; M6 reshapes via ExecutiveAnomaly
//   + AiCostTopPromptRow.
// - Distinguishes auth modes at the API layer: 'jwt' | 'signed-token' | 'none'.
//   M6 introduces NO new auth modes (Q1 — zero new PUBLIC; zero signed-token).
//   All 10 M6 endpoints are 'jwt'.
// - M3 PUBLIC fn_ allowlist (5 entries) preserved verbatim —
//   M6_PUBLIC_FN_ADDITIONS = 0.
// ============================================================

import type { ApiResponse } from './api.types';

// ------------------------------------------------------------
// 1. PUBLIC fn_ allowlist preservation (S2-21 mandatory)
// ------------------------------------------------------------
//
// Per Q1 (locked CONFIRM at Gate 2) — M6 introduces ZERO new PUBLIC
// SECURITY DEFINER fn_'s. All 10 M6 fn_'s have REVOKE ALL FROM PUBLIC
// + GRANT EXECUTE TO neondb_owner. Stage 4 enumerate-PUBLIC-grants must
// verify count = 5 post-migration. M3's 5 PUBLIC fn_'s remain the
// canonical allowlist; M6 = SIXTH-CONSECUTIVE-CLEAN module.
export const M3_PUBLIC_FN_ALLOWLIST = [
  'fn_signature_get_by_invitation_token',
  'fn_signature_sign',
  'fn_signature_decline',
  'fn_signer_qa_session_start',
  'fn_signer_qa_session_record_message',
] as const;

export type M3PublicFnName = typeof M3_PUBLIC_FN_ALLOWLIST[number];

/** M6 contributes ZERO new PUBLIC fn_ grants (Q1 locked CONFIRM). */
export const M6_PUBLIC_FN_ADDITIONS = [] as const;

// ------------------------------------------------------------
// 2. M6 permission codes (1 new — seeded in migration 054)
// ------------------------------------------------------------
//
// Q2 locked — 1 code seeded (insights.executive) + 3 role_permission grants
// (executive + platform_admin + Super Admin pre-emptive). Other M6 fn_'s
// gate on existing M0/M2/M4 permission codes (audit.read, ai.observability.read)
// plus in-body role checks; no new codes needed for those.
export const M6_NEW_PERMISSIONS = ['insights.executive'] as const;

export type M6PermissionCode = typeof M6_NEW_PERMISSIONS[number];

/** Cross-module permission codes consumed by M6 fn_'s but seeded by earlier modules. */
export const M6_REFERENCED_EXISTING_PERMISSIONS = [
  'audit.read', // M0-seeded; consumed by fn_dashboard_legal_counsel auditSummary gate (CRIT-4 lock)
  'ai.observability.read', // M4-seeded (migration 044); fn_dashboard_executive aiCostUsdWindow + fn_dashboard_ai_cost_summary entrypoint
] as const;

// ------------------------------------------------------------
// 3. Auth-mode marker (api-contracts.json discriminator)
// ------------------------------------------------------------

export type ApiAuthMode = 'jwt' | 'signed-token' | 'none';

// ------------------------------------------------------------
// 4. Time-window query parameters (shared across M6 dashboard endpoints)
// ------------------------------------------------------------
//
// All 7 dashboard endpoints (admin/drafter/approver/legal-counsel/recipient/
// executive/ai-cost-summary) accept an optional p_window_days INTEGER scalar.
// Defaults differ:
//   - Operational dashboards (admin/drafter/approver/legal-counsel/recipient):
//       default 30, range 1..365
//   - Executive dashboard:
//       default 90, range 1..365 (AI sub-call still capped to last 90)
//   - AI cost summary:
//       default 30, range 1..90 (matches M4 cap)
//   - Executive anomalies history:
//       default 10, range 1..50 (limit; not windowDays)
//
// All M6 dashboard fn_'s validate range and RAISE ERRCODE 22023 with
// { field: 'windowDays', message: '...' } when out of range. Zod coerce
// fires at the controller layer; the fn body re-validates as defence.
//
// The router endpoint (S6) accepts no parameters.
// fn_health_check (S12) accepts no parameters.

/** Optional time-window query param for dashboard endpoints. */
export interface DashboardWindowQuery {
  /** Rolling window in days. Range varies per endpoint (see endpoint contract). */
  windowDays?: number;
}

/** fn_dashboard_executive_anomalies_history limit query (1..50). */
export interface ExecutiveAnomaliesHistoryQuery {
  limit?: number;
}

// ------------------------------------------------------------
// 5. Enums backed by domain semantics (derived literals — not DB CHECK constraints)
// ------------------------------------------------------------

/**
 * fn_dashboard_router output — dashboardKey decision tree codified at
 * db-design.md §3.6. platform_admin / Super Admin → 'admin'. Default
 * fallback → 'recipient' (least-privilege view).
 */
export type DashboardKey =
  | 'admin'
  | 'drafter'
  | 'approver'
  | 'legal_counsel'
  | 'recipient'
  | 'executive';

/** fn_health_check overall status — composed from db.status + ai.estimatedHealthy. */
export type HealthStatusOverall = 'ok' | 'degraded' | 'unhealthy';

/** fn_health_check db.status — derived from CURRENT_TIMESTAMP and pg_is_in_recovery(). */
export type HealthDbStatus = 'ok' | 'degraded';

/**
 * Severity literal as projected by fn_dashboard_executive_anomalies_history
 * (passed through from M4 ai_insight rows; M5 RegulatorySeverity is a
 * different scope). Kept as a string union to allow forward-compatibility
 * with M4 anomaly cache rows.
 */
export type AnomalySeverity = string;

// ------------------------------------------------------------
// 6. Embedded shape — placeholder slot
// ------------------------------------------------------------
//
// Per OI-1 in requirements-analysis.json — Lovable's S29 ACs reference
// 'parties' and 'obligations' but no parties/obligation tables exist in
// M0..M5. Affected M6 dashboard projections return an explicit placeholder
// envelope so the FE can grey-out tiles with 'feature pending' tooltips:
//   - fn_dashboard_legal_counsel.kpis.templateUsageThisWindow
//   - fn_dashboard_recipient.kpis.myObligationsCount

export interface PlaceholderKpi {
  /** Always 0 for placeholder slots; FE renders disabled tile. */
  value: 0;
  /** Always true — distinguishes from a real zero-value count. */
  placeholder: true;
}

// ------------------------------------------------------------
// 7. Shared embedded shapes — list-row projections inside dashboard payloads
// ------------------------------------------------------------

/**
 * Lightweight contract row projected by dashboard list slots
 * (myDrafts5 / awaitingMyAction5 / myContracts5).
 * Source columns: contract.id, contract_number, title_en, title_ar, status,
 * value_aed, updated_at. NEVER includes contract_body (sensitive).
 *
 * NOTE: this is NOT a re-export of M1a Contract — it is a NEW lighter shape
 * for dashboard consumption. Contract from M1a is unchanged in M6.
 */
export interface DashboardContractRow {
  id: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  status: string;
  valueAed: number | null;
  updatedAt: string;
}

/** Drafter awaiting-action row — adds lastDecisionNote to the base shape. */
export interface DrafterAwaitingActionRow
  extends Omit<DashboardContractRow, 'valueAed' | 'updatedAt'> {
  lastDecisionNote: string | null;
}

/**
 * Approver pending-queue row — joined approval_step + contract.
 * Source: db-design.md §3.3 lists.pendingQueue5.
 */
export interface ApproverPendingQueueRow {
  stepId: number;
  contractId: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  valueAed: number | null;
  /** approval_step.created_at — replaces non-existent assigned_at (S2-22-FIX-2b). */
  requestedAt: string;
  /** EXTRACT(EPOCH FROM (NOW() - step.created_at))/3600 — decimal hours. */
  hoursWaiting: number;
}

/** Recipient my-contracts row — joined contract + signature_party. */
export interface RecipientMyContractsRow {
  id: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  status: string;
  /** signature_party.id where lower(signer_email) = lower(current_user.email). */
  ourPartyId: number;
  /** Always null for now — no parties table yet (db-design.md §3.5 explicit). */
  counterpartyId: null;
}

/** Recipient pending-signature row — joined signature_invitation + signature_party + contract. */
export interface RecipientPendingSignatureRow {
  invitationId: number;
  contractId: number;
  contractNumber: string;
  /** signature_invitation.invitation_sent_at AS sentAt (S2-22-FIX-5a). */
  sentAt: string;
  /** signature_invitation.invitation_expires_at AS expiresAt (S2-22-FIX-5a). */
  expiresAt: string | null;
}

/**
 * Recent regulatory update row — projected by fn_dashboard_legal_counsel
 * lists.recentRegulatoryUpdates5 (lighter shape than M5 RegulatoryUpdate).
 * Embeds a RegulatorRef-like sub-object.
 */
export interface DashboardRegulatoryUpdateRow {
  id: number;
  titleEn: string;
  severity: string;
  effectiveDate: string | null;
  regulator: { id: number; nameEn: string };
}

/**
 * Open regulatory-impact row — projected by fn_dashboard_legal_counsel
 * lists.openImpacts5 (lighter than M5 RegulatoryImpact). Lower-cardinality
 * projection optimised for tile rendering.
 */
export interface DashboardOpenImpactRow {
  id: number;
  contractId: number;
  contractNumber: string;
  regulationTitleEn: string;
  /** COALESCE(ru.severity, 'unknown') — db-design.md §3.4. */
  severity: string;
  detectedAt: string;
}

/**
 * Trend point — { date: 'YYYY-MM-DD', count: integer }.
 * Used by fn_dashboard_admin trends.contractsCreatedByDay (gap-filled via generate_series).
 */
export interface TrendDayCount {
  date: string;
  count: number;
}

/**
 * Approval-decision day point — separates approved vs rejected counts.
 * Source: db-design.md §3.1 trends.approvalDecisionsByDay
 * (FILTER (WHERE decision='approve'/'reject') — present-tense, S2-22-WARN-1-FIX).
 */
export interface ApprovalDecisionDayPoint {
  date: string;
  approved: number;
  rejected: number;
}

/** Monthly trend point — db-design.md §3.7. */
export interface TrendMonthCount {
  month: string; // YYYY-MM
  count: number;
}

/** Monthly value point — fn_dashboard_executive trends.valueOverTimeByMonth. */
export interface TrendMonthValueAed {
  month: string;
  totalValueAed: number;
}

/**
 * Counterparty concentration row — fn_dashboard_executive
 * topCounterpartiesByValue5. counterpartyName, counterpartyNameAr, and
 * counterpartyEmirate are now embedded by fn_dashboard_executive (CR-FIX1
 * DB migration); optional to remain compatible with older cached fn_ rows.
 */
export interface CounterpartyConcentrationRow {
  counterpartyId: number;
  totalValueAed: number;
  contractCount: number;
  counterpartyName?: string;
  counterpartyNameAr?: string | null;
  counterpartyEmirate?: string | null;
}

/**
 * Value-distribution histogram bucket — fn_dashboard_executive valueDistribution.
 * Bucket labels per Architect spec: '<100k' / '100k-1M' / '1M-10M' / '10M+'.
 */
export interface ValueDistributionBucket {
  bucket: string;
  count: number;
}

/** Top-prompt cost row — fn_dashboard_ai_cost_summary topPromptsByCost5. */
export interface AiCostTopPromptRow {
  promptId: number;
  /** successCount + errorCount per fn_ai_request_log_cost_report (M4 043). */
  requestCount: number;
  /** totalCostUsdMicros / 1_000_000 — projected as USD with 2dp at FE (AC-S11-07). */
  totalCostUsd: number;
  /** null when prompt has zero successful requests (S2-18 NULL semantic). */
  cacheHitRatio: number | null;
}

// ------------------------------------------------------------
// 8. fn_dashboard_admin (S1, S13) response shape
// ------------------------------------------------------------

/**
 * AdminDashboardKpis — derived from db-design.md §3.1 JSONB OUTPUT
 * (post Patch Round 1: live indexes + present-tense decision enum).
 */
export interface AdminDashboardKpis {
  totalContractsActive: number;
  /** jsonb_object_agg(contract.status, count) — keys are contract.status literals ('draft','approved',...). */
  totalContractsByStatus: Record<string, number>;
  expiringWithin30d: number;
  /** AC-S1-04 monotonic — expiringWithin30d <= expiringWithin90d. */
  expiringWithin90d: number;
  pendingApprovals: number;
  pendingSignatures: number;
  /** WHERE resolved = FALSE AND is_active = TRUE — per CRIT-1 rewrite (no resolved_at column). */
  openRegulatoryImpacts: number;
  recentAuditEvents: number;
  totalActiveUsers: number;
}

export interface AdminDashboardTrends {
  contractsCreatedByDay: TrendDayCount[];
  /** approve/reject filter (S2-22-WARN-1-FIX present-tense literals). */
  approvalDecisionsByDay: ApprovalDecisionDayPoint[];
}

export interface AdminDashboardSnapshot {
  kpis: AdminDashboardKpis;
  trends: AdminDashboardTrends;
}

// ------------------------------------------------------------
// 9. fn_dashboard_drafter (S2) response shape
// ------------------------------------------------------------

export interface DrafterDashboardKpis {
  myDraftsCount: number;
  awaitingMyActionCount: number;
  /** WHERE drafted_by = caller AND status = 'approved' AND is_active = TRUE AND id NOT IN (signature_invitation). */
  readyToSendCount: number;
  myRecentlyApprovedCount: number;
}

export interface DrafterDashboardLists {
  myDrafts5: DashboardContractRow[];
  awaitingMyAction5: DrafterAwaitingActionRow[];
}

export interface DrafterDashboardSnapshot {
  kpis: DrafterDashboardKpis;
  lists: DrafterDashboardLists;
}

// ------------------------------------------------------------
// 10. fn_dashboard_approver (S3) response shape
// ------------------------------------------------------------

export interface ApproverDashboardKpis {
  /**
   * COUNT WHERE COALESCE(delegated_to, reassigned_to, approver_user_id) IS NOT DISTINCT FROM v_user_id
   * AND status='pending' AND is_active=TRUE (S2-22-FIX-2a + S2-18 NULL-safe).
   */
  pendingMyApprovalCount: number;
  /** decided_by = caller AND decided_at >= NOW() - p_window_days days (S2-22-FIX-3). */
  decidedByMeCount: number;
  /** AVG hours via approval_step.created_at (S2-22-FIX-2b). NULL when 0 decisions in window. */
  averageDecisionHoursMine: number | null;
  /** Same shape, OTHER users with the same approver_role. */
  averageDecisionHoursTeam: number | null;
}

export interface ApproverDashboardLists {
  pendingQueue5: ApproverPendingQueueRow[];
}

export interface ApproverDashboardSnapshot {
  kpis: ApproverDashboardKpis;
  lists: ApproverDashboardLists;
}

// ------------------------------------------------------------
// 11. fn_dashboard_legal_counsel (S4) response shape
// ------------------------------------------------------------

export interface LegalCounselDashboardKpis {
  regulatoryUpdatesThisWindow: number;
  /** WHERE resolved = FALSE AND is_active = TRUE (CRIT-1 rewrite). */
  openRegulatoryImpacts: number;
  criticalSeverityCount: number;
  regulationCatalogSize: number;
  /** Explicit placeholder until templates module ships (AC-S4-05). */
  templateUsageThisWindow: PlaceholderKpi;
  /**
   * jsonb_object_agg(table_name, count) FROM audit_log; keys are LIVE
   * audit_log.table_name values (S2-22-FIX-4 — was entity_type which doesn't
   * exist). NULL when caller lacks 'audit.read' permission (CRIT-4 lock —
   * NOT 'audit.read.all').
   */
  auditSummary: Record<string, number> | null;
}

export interface LegalCounselDashboardLists {
  recentRegulatoryUpdates5: DashboardRegulatoryUpdateRow[];
  openImpacts5: DashboardOpenImpactRow[];
}

export interface LegalCounselDashboardSnapshot {
  kpis: LegalCounselDashboardKpis;
  lists: LegalCounselDashboardLists;
}

// ------------------------------------------------------------
// 11b. fn_dashboard_legal_counsel_insights (mig 685) response shape
// ------------------------------------------------------------

export interface LegalCounselInsightsKpis {
  contractsPendingMyReview: number;
  advisoriesInProgress: number;
  tpaReviewsAwaitingMe: number;
  myOpenRiskCases: number;
}

export interface LegalCounselAdvisoryPipeline {
  draft: number;
  inExecReview: number;
  approvedReady: number;
  sentThisMonth: number;
}

// mig 686 — named lifecycle buckets.
export interface LegalCounselTpaPipeline {
  received: number;
  awaitingOurReview: number;
  reviewed: number;
  awaitingCounterparty: number;
  accepted: number;
  rejected: number;
}

export interface LegalCounselTemplateClause {
  templateCount: number;
  clauseCount: number;
  approvedClauseCount: number;
}

export interface LegalCounselRiskCaseRow {
  id: number;
  title: string;
  caseType: string;
  status: string;
  priority: string;
}

// mig 686 — avg legal review time, days, glitch-filtered.
export interface LegalCounselAvgReview {
  avgDays: number;
  sampleSize: number;
  series12w: Array<{ weekIndex: number; avgDays: number }>;
}

export interface LegalCounselInsightsSnapshot {
  kpis: LegalCounselInsightsKpis;
  advisoryPipeline: LegalCounselAdvisoryPipeline;
  tpaPipeline: LegalCounselTpaPipeline;
  templateClause: LegalCounselTemplateClause;
  myRiskCases: LegalCounselRiskCaseRow[];
  avgReview: LegalCounselAvgReview;
}

// ------------------------------------------------------------
// 12. fn_dashboard_recipient (S5) response shape
// ------------------------------------------------------------

export interface RecipientDashboardKpis {
  /** DISTINCT contracts where caller is a signature_party (lower(email) match). */
  myContractsCount: number;
  /** signature_invitation rows assigned to caller's email AND status='pending'. */
  pendingMySignatureCount: number;
  /**
   * signature_event WHERE actor_user_id = v_user_id AND event_type='signed'
   * AND created_at >= NOW() - p_window_days days AND is_active = TRUE
   * (S2-22-FIX-1a/1b/1c — was signer_user_id/signed_at/outcome; none exist).
   *
   * Semantic limitation (DN-19): actor_user_id IS NULL for external-only
   * invitation signers — they are NOT counted here. Acceptable for the
   * recipient dashboard because internal recipients (UAE-PASS / app-authenticated)
   * DO populate actor_user_id; external-only is an edge case.
   */
  signedByMeWindow: number;
  /** Placeholder until obligations module ships (AC-S5-04). */
  myObligationsCount: PlaceholderKpi;
}

export interface RecipientDashboardLists {
  myContracts5: RecipientMyContractsRow[];
  pendingSignatures5: RecipientPendingSignatureRow[];
}

export interface RecipientDashboardSnapshot {
  kpis: RecipientDashboardKpis;
  lists: RecipientDashboardLists;
}

// ------------------------------------------------------------
// 13. fn_dashboard_router (S6) response shape
// ------------------------------------------------------------

export interface DashboardPermissionsSummary {
  canViewAdminDashboard: boolean;
  canViewExecutiveDashboard: boolean;
}

/**
 * fn_dashboard_router JSONB output (db-design.md §3.6).
 *
 * Note: Orchestrator prompt mentioned `DashboardRouterResponse = { roleSlug, dashboardSlug }`,
 * but the authoritative DB design (§3.6 Patch Round 1, S2-22-WARN-3-FIX) returns
 * { userId, primaryRole, dashboardKey, permissionsSummary }. Per
 * feedback_db_impl_report_dont_fix.md we honor the DB design over the prompt
 * shorthand — the actual fn_ JSONB is what the FE receives.
 */
export interface DashboardRouterResponse {
  userId: number;
  /**
   * Raw role.name as resolved via fn_user_get_by_id v_user->'role'->>'name'
   * (with COALESCE fallback to 'unknown'; S2-22-WARN-3-FIX).
   */
  primaryRole: string;
  /** Decision tree codified at db-design.md §3.6 step 4. Default fallback: 'recipient'. */
  dashboardKey: DashboardKey;
  permissionsSummary: DashboardPermissionsSummary;
}

// ------------------------------------------------------------
// 14. fn_dashboard_executive (S7) response shape — INCLUDES inline AI cost
// ------------------------------------------------------------

export interface ExecutiveExpiryCliffs {
  next30d: number;
  /** AC-S7-03 monotonic: next30d <= next60d <= next90d. */
  next60d: number;
  next90d: number;
}

export interface ExecutiveDashboardKpis {
  totalActiveValueAed: number;
  contractsByStatus: Record<string, number>;
  expiryCliffs: ExecutiveExpiryCliffs;
  topCounterpartiesByValue5: CounterpartyConcentrationRow[];
  valueDistribution: ValueDistributionBucket[];
  /** WHERE ri.resolved = FALSE AND ru.severity = 'critical' (CRIT-1 + M5 join). */
  openRegulatoryImpactsCritical: number;
  /**
   * Q5 — Inline AI cost figure derived from fn_ai_request_log_cost_report.
   * NULL when caller lacks ai.observability.read (AC-S7-05 explicit marker).
   * 90-day cap inherited from M4 even if p_window_days > 90 (LEAST clause).
   */
  aiCostUsdWindow: number | null;
}

export interface ExecutiveDashboardTrends {
  valueOverTimeByMonth: TrendMonthValueAed[];
  contractsCreatedByMonth: TrendMonthCount[];
}

export interface ExecutiveDashboardSnapshot {
  kpis: ExecutiveDashboardKpis;
  trends: ExecutiveDashboardTrends;
}

// ------------------------------------------------------------
// 15. fn_dashboard_executive_anomalies_history (S8) response shape
// ------------------------------------------------------------

/**
 * One anomaly row — shape projected by fn_dashboard_executive_anomalies_history
 * step 4 (db-design.md §3.8). Reshaped from M4 fn_ai_insight_list rows
 * (entity_type='executive_anomalies'); detectedAt is sourced from
 * ai_insight.created_at (no detected_at column on ai_insight).
 */
export interface ExecutiveAnomaly {
  id: number;
  summaryEn: string | null;
  summaryAr: string | null;
  severity: AnomalySeverity;
  detectedAt: string;
  /** Free-form payload from M4 ai_insight.payload column — JSON. */
  payload: Record<string, unknown> | null;
}

export interface ExecutiveAnomaliesHistoryResponse {
  /** Empty array (NOT 404) when ai_insight cache empty — AC-S8-02. */
  anomalies: ExecutiveAnomaly[];
}

// ------------------------------------------------------------
// 16. fn_dashboard_ai_cost_summary (S11) response shape
// ------------------------------------------------------------

/**
 * AiCostSummary — used by S11 standalone endpoint AND by S7 inline
 * (kpis.aiCostUsdWindow is derived from this same fn_'s totalCostUsdWindow).
 *
 * Per Q5 architect lock: vw_ai_cost_rollup DROPPED — single source of compute
 * is fn_ai_request_log_cost_report (M4 043) wrapped by fn_dashboard_ai_cost_summary.
 */
export interface AiCostSummary {
  totalCostUsdWindow: number;
  totalRequestsWindow: number;
  /** NULL when totalRequestsWindow = 0 — matches M4 fn_ai_request_log_cost_report semantic (S2-18). */
  cacheHitRatioOverall: number | null;
  topPromptsByCost5: AiCostTopPromptRow[];
}

// ------------------------------------------------------------
// 17. fn_health_check (S12) response shape — ARCH-NEW-3 option (c)
// ------------------------------------------------------------

/**
 * HealthCheckSnapshot — db-design.md §3.10 (Patch Round 1).
 *
 * The audit block (errorCountLastHour + lastErrorAt) was DROPPED in Patch
 * Round 1 (S2-22-WARN-2-FIX) — audit_log.action CHECK enum is
 * ('INSERT','UPDATE','DELETE') only; literal 'ERROR' could never match.
 * Error signal sourced from ai probe via ai_request_log.outcome.
 *
 * latestMigration depends on schema_migrations_select_admin SELECT policy
 * (migration 054, ARCH-NEW-3 option c). Without that policy the deny-all
 * RLS would return NULL.
 */
export interface HealthCheckDb {
  status: HealthDbStatus;
  /** MAX(version) FROM schema_migrations — NULL when policy missing or table empty. */
  latestMigration: number | null;
  /** Server-side CURRENT_TIMESTAMP. */
  currentTimestamp: string;
}

export interface HealthCheckAi {
  /** MAX(ai_request_log.created_at) WHERE outcome = 'success'. */
  lastSuccessfulRequestAt: string | null;
  /** MAX(ai_request_log.created_at) WHERE outcome IN ('error','timeout','rate_limited','cancelled'). */
  lastFailureAt: string | null;
  /** lastSuccessfulRequestAt IS NOT NULL AND (lastFailureAt IS NULL OR lastSuccessfulRequestAt > lastFailureAt). */
  estimatedHealthy: boolean;
}

export interface HealthCheckSnapshot {
  db: HealthCheckDb;
  ai: HealthCheckAi;
  overall: HealthStatusOverall;
}

// ------------------------------------------------------------
// 18. RESPONSE ENVELOPE ALIASES (M0 ApiResponse<T> wrappers — conceptual)
// ------------------------------------------------------------
//
// All M6 endpoints return the fn_ JSONB verbatim via res.status(200).json(result).
// The ApiResponse<T> aliases below mirror M5 regulatory.types.ts conventions
// but the actual wire payload is the inner T (matches the M5 pass-through
// pattern: services/regulatory.service.ts returns the typed inner shape;
// controllers `res.json(result)` without re-wrapping). Consumers that want
// the formal envelope can layer it client-side.

export type AdminDashboardEnvelope = ApiResponse<AdminDashboardSnapshot>;
export type DrafterDashboardEnvelope = ApiResponse<DrafterDashboardSnapshot>;
export type ApproverDashboardEnvelope = ApiResponse<ApproverDashboardSnapshot>;
export type LegalCounselDashboardEnvelope = ApiResponse<LegalCounselDashboardSnapshot>;
export type RecipientDashboardEnvelope = ApiResponse<RecipientDashboardSnapshot>;
export type DashboardRouterEnvelope = ApiResponse<DashboardRouterResponse>;
export type ExecutiveDashboardEnvelope = ApiResponse<ExecutiveDashboardSnapshot>;
export type ExecutiveAnomaliesHistoryEnvelope = ApiResponse<ExecutiveAnomaliesHistoryResponse>;
export type AiCostSummaryEnvelope = ApiResponse<AiCostSummary>;
export type HealthCheckEnvelope = ApiResponse<HealthCheckSnapshot>;
