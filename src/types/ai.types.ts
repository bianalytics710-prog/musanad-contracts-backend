// ============================================================
// M4 — AI Features — TypeScript Type Definitions (BE)
// Mirrors Agent 5 workspace types.ts (the canonical source). Local copy
// here so the backend repo is self-contained for tsc.
//
// Cross-module touchpoints:
// - Extends ActivityType union (M3 20 → M4 23) — see M4_ACTIVITY_TYPE_EXTENSIONS.
// - Reuses contract.ai_summary_en/ai_summary_ar/ai_risk_score reserved columns
//   (M1a 003) — surfaced via ContractAiSummaryPersistData.
// - Reuses contract_version.diff_summary (M1a 003).
// - Distinguishes 3 auth modes at the API layer: 'jwt' | 'signed-token' | 'none'.
// - M3 PUBLIC fn_ allowlist preserved verbatim — M4 PUBLIC additions = 0.
// ============================================================

import type { ApiResponse, PaginationMeta } from './api.types';
import type { ActivityType as M3ActivityType } from './contracts.types';

// ------------------------------------------------------------
// 1. ActivityType extension — M3 (20) -> M4 (23)
// ------------------------------------------------------------
export const M4_ACTIVITY_TYPE_EXTENSIONS = [
  'ai_summary_generated',
  'ai_risk_score_updated',
  'ai_diff_summary_generated',
] as const;

export type M4ActivityTypeExtension = typeof M4_ACTIVITY_TYPE_EXTENSIONS[number];

/** M4 widened activity-type union — 23 values (M1a 7 + M1b 2 + M2 5 + M3 6 + M4 3). */
export type M4ActivityType = M3ActivityType | M4ActivityTypeExtension;

// ------------------------------------------------------------
// 2. Sensitive-field marker (controller-only — not a DB column)
// ------------------------------------------------------------
export const M4_SENSITIVE_FIELD_EXTENSIONS = ['ai_prompt_payload'] as const;
export type M4SensitiveFieldName = typeof M4_SENSITIVE_FIELD_EXTENSIONS[number];

// ------------------------------------------------------------
// 3. M3 PUBLIC fn_ allowlist preservation (S2-21)
// ------------------------------------------------------------
export const M3_PUBLIC_FN_ALLOWLIST = [
  'fn_signature_get_by_invitation_token',
  'fn_signature_sign',
  'fn_signature_decline',
  'fn_signer_qa_session_start',
  'fn_signer_qa_session_record_message',
] as const;
export type M3PublicFnName = typeof M3_PUBLIC_FN_ALLOWLIST[number];

/** M4 contributes ZERO new PUBLIC fn_ grants (Q3 Option A). */
export const M4_PUBLIC_FN_ADDITIONS = [] as const;

// ------------------------------------------------------------
// 4. M4 permission codes (4 new)
// ------------------------------------------------------------
export const M4_NEW_PERMISSIONS = [
  'ai.invoke.contract',
  'ai.invoke.executive',
  'ai.invoke.regulatory',
  'ai.observability.read',
] as const;
export type M4PermissionCode = typeof M4_NEW_PERMISSIONS[number];

// ------------------------------------------------------------
// 5. M4 prompt-id constants (6 in-scope prompts)
// ------------------------------------------------------------
export const M4_PROMPT_IDS = [
  'ai-contract-insights',
  'ai-drafting-assistant',
  'ai-executive-anomalies',
  'ai-regulatory-impact',
  'ai-regulatory-impact-summary',
  'ai-version-diff-summary',
] as const;
export type M4PromptId = typeof M4_PROMPT_IDS[number];

// ------------------------------------------------------------
// 6. Shared enums backed by DB CHECK constraints
// ------------------------------------------------------------
export type AiLanguage = 'en' | 'ar' | 'bilingual';
export type AiProvider = 'openai' | 'anthropic';
export type AiRequestOutcome = 'success' | 'error' | 'timeout' | 'rate_limited' | 'cancelled';

export type AiContractInsightsMode =
  | 'summary'
  | 'key_terms'
  | 'risks'
  | 'obligations'
  | 'regulatory'
  | 'rewrite';

export type AiDraftingAssistantMode = 'suggest' | 'explain' | 'rewrite' | 'chat';
export type AiDraftingAssistantTone = 'simpler' | 'formal' | 'stronger' | 'balanced';
export type AiRegulatoryImpactMode = 'explain' | 'amendment';

export type AiInsightType =
  | 'contract_summary'
  | 'contract_key_terms'
  | 'contract_risks'
  | 'contract_obligations'
  | 'contract_regulatory'
  | 'contract_rewrite'
  | 'version_diff_summary'
  | 'executive_anomalies'
  | 'regulatory_impact_explain'
  | 'regulatory_impact_amendment'
  | 'regulatory_impact_summary'
  // M15 (CR-G) — AI Risk Assistant Q&A response cache
  | 'qa_response';

export type AiInsightEntityType =
  | 'contract'
  | 'contract_version'
  | 'regulatory_update'
  | 'regulatory_update_summary'
  | 'executive_dashboard'
  // M15 (CR-G) — AI Risk Assistant per-query scope (keyed by scope_hash derivation)
  | 'risk_assistant_query';

// ------------------------------------------------------------
// 7. ai_prompt entity types
// ------------------------------------------------------------
export interface AiPrompt {
  promptId: M4PromptId | string;
  descriptionEn: string;
  descriptionAr: string;
  defaultModel: string;
  defaultTemperature: number;
  defaultMaxTokens: number;
  defaultTtlSeconds: number;
  supportsStreaming: boolean;
  supportsToolCall: boolean;
  publicEndpoint: boolean;
  promptFilePath: string;
  rateLimitPerUserPerHour: number;
  rateLimitPerUserPerDay: number;
  isActive: boolean;
}

export interface AiPromptListResponse {
  data: AiPrompt[];
  pagination: PaginationMeta;
}

export interface AiPromptListQuery {
  includeInactive?: boolean;
}

// ------------------------------------------------------------
// 8. ai_insight entity types
// ------------------------------------------------------------
export interface AiInsight {
  id: number;
  entityType: AiInsightEntityType;
  entityId: number | null;
  insightType: AiInsightType;
  language: AiLanguage;
  promptId: M4PromptId | string;
  provider: AiProvider;
  modelUsed: string;
  payload: AiInsightPayload;
  payloadHash: string;
  tokensInput: number | null;
  tokensOutput: number | null;
  costUsdMicros: number | null;
  expiresAt: string;
  createdAt: string;
}

export interface AiInsightUpsertResult {
  id: number;
  expiresAt: string;
}

export interface AiInsightEvictExpiredResult {
  evictedCount: number;
}

export interface AiInsightListItem extends AiInsight {
  isActive: boolean;
}

export interface AiInsightListResponse {
  data: AiInsightListItem[];
  pagination: PaginationMeta;
}

export interface AiInsightListQuery {
  page?: number;
  limit?: number;
  entityType?: AiInsightEntityType;
  insightType?: AiInsightType;
  language?: AiLanguage;
  provider?: AiProvider;
  includeExpired?: boolean;
}

// ------------------------------------------------------------
// 8.1 ai_insight payload variants (discriminated union)
// ------------------------------------------------------------
export interface AiContractSummaryPayload {
  insightType: 'contract_summary';
  summary: string;
  riskScore?: number | null;
  language: AiLanguage;
}

export interface AiContractKeyTermsPayload {
  insightType: 'contract_key_terms';
  keyTerms: Array<{
    label: string;
    value: string;
    clauseAnchor?: string | null;
    clauseExcerpt?: string | null;
  }>;
}

export interface AiContractRisksPayload {
  insightType: 'contract_risks';
  risks: Array<{
    title: string;
    severity: 'high' | 'medium' | 'low';
    clauseAnchor: string;
    clauseExcerpt: string;
    rationale: string;
  }>;
}

export interface AiContractObligationsPayload {
  insightType: 'contract_obligations';
  obligations: Array<{
    party: string;
    obligation: string;
    deadline?: string | null;
    clauseAnchor?: string | null;
  }>;
}

export interface AiContractRegulatoryPayload {
  insightType: 'contract_regulatory';
  regulations: Array<{
    citation: string;
    relevance: string;
    clauseAnchor?: string | null;
  }>;
}

export interface AiContractRewritePayload {
  insightType: 'contract_rewrite';
  rewrittenText: string;
}

export interface AiExecutiveAnomaliesPayload {
  insightType: 'executive_anomalies';
  anomalies: Array<{
    insight: string;
    severity: 'info' | 'warning' | 'critical';
    drillDownFilter: string;
  }>;
  generatedAt: string;
}

export interface AiVersionDiffSummaryPayload {
  insightType: 'version_diff_summary';
  summary: string;
}

export interface AiRegulatoryImpactPayload {
  insightType: 'regulatory_impact_explain' | 'regulatory_impact_amendment';
  text: string;
}

export interface AiRegulatoryImpactSummaryPayload {
  insightType: 'regulatory_impact_summary';
  executive: string;
  keyChanges: string[];
  recommendedActions: string[];
}

/** M15 (CR-G) — AI Risk Assistant Q&A cache payload. */
export interface AiRiskAssistantQaPayload {
  insightType: 'qa_response';
  answer: string;
  citations: Array<{
    type: 'clause' | 'correlation' | 'signal' | 'contract';
    id: string;
    label: string;
    href: string;
    excerpt?: string;
  }>;
}

export type AiInsightPayload =
  | AiContractSummaryPayload
  | AiContractKeyTermsPayload
  | AiContractRisksPayload
  | AiContractObligationsPayload
  | AiContractRegulatoryPayload
  | AiContractRewritePayload
  | AiExecutiveAnomaliesPayload
  | AiVersionDiffSummaryPayload
  | AiRegulatoryImpactPayload
  | AiRegulatoryImpactSummaryPayload
  // M15 (CR-G) — AI Risk Assistant
  | AiRiskAssistantQaPayload;

// ------------------------------------------------------------
// 9. ai_request_log entity types
// ------------------------------------------------------------
export interface AiRequestLogActor {
  id: number;
  email: string;
  fullName: string;
}

export interface AiRequestLogListItem {
  id: number;
  requestId: string;
  promptId: M4PromptId | string;
  mode: string | null;
  actor: AiRequestLogActor | null;
  entityType: AiInsightEntityType | string | null;
  entityId: number | null;
  language: AiLanguage;
  provider: AiProvider;
  modelUsed: string;
  tokensInput: number | null;
  tokensOutput: number | null;
  costUsdMicros: number | null;
  latencyMs: number | null;
  cacheHit: boolean;
  streamMode: boolean;
  outcome: AiRequestOutcome;
  errorClass: string | null;
  /** SENSITIVE — pino-redacted at controller before logging. */
  errorMessage: string | null;
  createdAt: string;
}

export interface AiRequestLogListResponse {
  data: AiRequestLogListItem[];
  pagination: PaginationMeta;
}

export interface AiRequestLogListQuery {
  page?: number;
  limit?: number;
  actorUserId?: number;
  promptId?: M4PromptId | string;
  outcome?: AiRequestOutcome;
  fromDate?: string;
  toDate?: string;
}

export interface AiRequestLogCreateResult {
  id: number;
  requestId: string;
}

export interface AiRateLimitCheckResult {
  allowed: boolean;
  remainingHour: number;
  remainingDay: number;
  retryAfterSeconds: number;
}

// ------------------------------------------------------------
// 10. AI cost report (S12)
// ------------------------------------------------------------
export interface AiCostReportRow {
  promptId: M4PromptId | string;
  actor?: AiRequestLogActor | null;
  totalCostUsdMicros: number;
  totalTokensInput: number;
  totalTokensOutput: number;
  successCount: number;
  errorCount: number;
  avgLatencyMs: number | null;
  cacheHitRatio: number | null;
}

export interface AiCostReportResponse {
  data: AiCostReportRow[];
}

export interface AiCostReportQuery {
  fromDate: string;
  toDate: string;
  groupByUser?: boolean;
}

// ------------------------------------------------------------
// 11. fn_contract_ai_summary_persist + fn_contract_version_diff_summary_persist
// ------------------------------------------------------------
export interface ContractAiSummaryPersistData {
  contractId: number;
  aiSummaryEn: string | null;
  aiSummaryAr: string | null;
  aiRiskScore: number | null;
  updatedAt: string;
}

export interface ContractVersionDiffSummaryPersistData {
  contractVersionId: number;
  diffSummary: string;
  updatedAt: string;
}

// ============================================================
// 12. Per-prompt SERVICE CONTRACTS
// ============================================================

// ----- 12.1 ai-contract-insights (S1) -----
export interface AiContractInsightsRequest {
  contractId: number;
  mode: AiContractInsightsMode;
  language: AiLanguage;
  /** Required when mode='rewrite'. SENSITIVE — never log. */
  selectedText?: string;
}

export type AiContractInsightsResponseBody =
  | { mode: 'key_terms'; payload: AiContractKeyTermsPayload }
  | { mode: 'risks'; payload: AiContractRisksPayload }
  | { mode: 'obligations'; payload: AiContractObligationsPayload }
  | { mode: 'regulatory'; payload: AiContractRegulatoryPayload };

export type AiInsightsStreamChunk =
  | { type: 'token'; delta: string }
  | { type: 'done'; tokensConsumed: number; persisted?: ContractAiSummaryPersistData | null }
  | { type: 'error'; code: string; message?: string; retryAfterSeconds?: number };

// ----- 12.2 ai-drafting-assistant (S2) -----
export interface AiDraftingAssistantChatTurn {
  role: 'user' | 'assistant';
  content: string;
}

export interface AiDraftingAssistantRequest {
  mode: AiDraftingAssistantMode;
  contractType: string;
  partyA: string;
  partyB?: string;
  draftSummary: string;
  existingClauseCategories: string[];
  language: AiLanguage;
  selectedText?: string;
  tone?: AiDraftingAssistantTone;
  chatHistory?: AiDraftingAssistantChatTurn[];
}

export type AiDraftingAssistantStreamChunk =
  | { type: 'token'; delta: string }
  | { type: 'done'; tokensConsumed: number }
  | { type: 'error'; code: string; message?: string; retryAfterSeconds?: number };

export interface AiDraftingAssistantSuggestion {
  kind: 'missing_clause' | 'weak_clause' | 'regulatory';
  title: string;
  rationale: string;
  proposedText: string;
}

export interface AiDraftingAssistantSuggestResponse {
  suggestions: AiDraftingAssistantSuggestion[];
}

// ----- 12.3 ai-executive-anomalies (S3) -----
export interface AiExecutiveAnomaliesStats {
  totalActiveValueAed?: number;
  contractsByStatus?: Record<string, number>;
  expiryCliffs?: Array<{ window: string; count: number }>;
  supplierConcentration?: Array<{ supplier: string; share: number }>;
  [key: string]: unknown;
}

export interface AiExecutiveAnomaliesRequest {
  stats: AiExecutiveAnomaliesStats;
  dateRange?: {
    fromDate: string;
    toDate: string;
  };
  language: AiLanguage;
}

export interface AiExecutiveAnomaliesResponse {
  anomalies: AiExecutiveAnomaliesPayload['anomalies'];
  generatedAt: string;
}

// ----- 12.4 ai-regulatory-impact (S4) -----
export interface AiRegulatoryImpactSampleContract {
  contractNumber: string;
  titleEn: string;
  contractType: string;
  valueAed?: number | null;
}

export interface AiRegulatoryImpactRequest {
  mode: AiRegulatoryImpactMode;
  regulator: string;
  referenceNumber?: string;
  titleEn: string;
  summaryEn?: string;
  effectiveDate?: string;
  complianceDeadline?: string;
  affectedClauseCategories: string[];
  impactedCount?: number;
  sampleContracts: AiRegulatoryImpactSampleContract[];
  language: AiLanguage;
  impactCategoryName?: string;
  impactCategoryGuidance?: string;
}

export type AiRegulatoryImpactStreamChunk =
  | { type: 'token'; delta: string }
  | { type: 'done'; tokensConsumed: number }
  | { type: 'error'; code: string; message?: string; retryAfterSeconds?: number };

// ----- 12.5 ai-regulatory-impact-summary (S5) -----
export interface AiRegulatoryImpactSummaryContract {
  contractNumber: string;
  title: string;
  type: string;
  valueAed?: number | null;
  impactScore?: number | null;
}

export interface AiRegulatoryImpactSummaryRequest {
  regulator: string;
  title: string;
  severity: string;
  referenceNumber?: string;
  summary?: string;
  contracts: AiRegulatoryImpactSummaryContract[];
  language: 'en' | 'ar';
  signedToken?: string;
}

export interface AiRegulatoryImpactSummaryResponse {
  executive: string;
  keyChanges: string[];
  recommendedActions: string[];
  cacheHit: boolean;
}

// ----- 12.6 ai-version-diff-summary (S6) -----
export interface AiVersionDiffSummaryRequest {
  contractId: number;
  leftVersionId: number;
  rightVersionId: number;
  additions: string;
  deletions: string;
  modifiedClauses: Array<{ clauseName: string; before?: string; after?: string }>;
  language: AiLanguage;
}

export interface AiVersionDiffSummaryResponse {
  summary: string;
  persisted: ContractVersionDiffSummaryPersistData;
  cacheHit: boolean;
}

// ============================================================
// 13. RESPONSE ENVELOPES
// ============================================================
export type AiPromptResponse = ApiResponse<AiPrompt | null>;
export type AiPromptListEnvelope = ApiResponse<AiPromptListResponse>;
export type AiInsightListEnvelope = ApiResponse<AiInsightListResponse>;
export type AiRequestLogListEnvelope = ApiResponse<AiRequestLogListResponse>;
export type AiCostReportEnvelope = ApiResponse<AiCostReportResponse>;
export type AiContractInsightsResponse = ApiResponse<AiContractInsightsResponseBody>;
export type AiDraftingAssistantSuggestEnvelope = ApiResponse<AiDraftingAssistantSuggestResponse>;
export type AiExecutiveAnomaliesEnvelope = ApiResponse<AiExecutiveAnomaliesResponse>;
export type AiRegulatoryImpactSummaryEnvelope = ApiResponse<AiRegulatoryImpactSummaryResponse>;
export type AiVersionDiffSummaryEnvelope = ApiResponse<AiVersionDiffSummaryResponse>;

// ============================================================
// 14. AUTH MODE MARKER
// ============================================================
export type ApiAuthMode = 'jwt' | 'signed-token' | 'none';

// ============================================================
// 15. Signed-PDF-token payload (S5 middleware)
// ============================================================
/**
 * Decoded signed-PDF-token payload. HMAC-validated at the Express middleware
 * layer before the controller runs. Per Q3 Option A — fn_'s remain
 * neondb_owner-only; the token is the gate for the public endpoint.
 */
export interface SignedPdfTokenClaims {
  sub: string; // request subject (e.g. PDF render id / contract scope)
  aud: 'regulatory-impact-pdf';
  iss: string;
  iat: number;
  exp: number;
  jti?: string;
}
