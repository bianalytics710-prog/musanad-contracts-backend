// ============================================================
// M5 — Regulatory Radar — TypeScript Type Definitions (BE)
// Mirrors workspace/current-module/types.ts (canonical Agent 5 source).
// Local copy here so the backend repo is self-contained for tsc.
//
// Cross-module touchpoints:
// - Extends ActivityType union (M4: 23 values -> M5: 25 values) — see
//   M5_ACTIVITY_TYPE_EXTENSIONS. S2-19: literal values must match the
//   047 atomic CHECK enum + fn_contract_activity_create whitelist
//   byte-for-byte.
// - Imports M4ActivityType from ai.types.ts (the 23-value alias). Adds 2
//   new M5 literals (regulatory_impact_detected, regulatory_impact_resolved)
//   to reach 25. NO modification to the M1a-owned ActivityType union in
//   contracts.types.ts — extension lives in this M5 file only.
// - Reuses Contract / ContractListItem (M1a) — Q11 NOT EXTEND:
//   fn_contract_get_by_id projection unchanged. Contract interface stays
//   unchanged in M5.
// - Reuses AiInsightEntityType (M4) which already includes
//   'regulatory_update' + 'regulatory_update_summary' literals.
// - Distinguishes auth modes at the API layer: 'jwt' | 'signed-token' | 'none'.
//   M5 introduces NO new auth modes (Q1 — zero new PUBLIC fn_'s; zero new
//   signed-token endpoints). All 15 M5 endpoints are 'jwt'.
// - M3 PUBLIC fn_ allowlist (5 entries) preserved verbatim —
//   M5_PUBLIC_FN_ADDITIONS = 0.
// ============================================================

import type { ApiResponse, PaginationMeta } from './api.types';
import type { Contract } from './contracts.types';
import type { M4ActivityType } from './ai.types';

// ------------------------------------------------------------
// 1. ActivityType extension — M4 (23) -> M5 (25)
// ------------------------------------------------------------
//
// S2-19: literal values MUST exactly match migration 047's CHECK enum
// additions. DB constraint name: contract_activity_activity_type_check
// (M1b 010 stable; dynamic pg_constraint lookup in migration 047).
//
// Per Q9 (locked EMIT) — fn_contract_activity_create whitelist 23->25 in
// migration 047 (atomic with CHECK enum extension). Byte-for-byte additive:
// the 23 existing M4ActivityType values are preserved; only the IF NOT IN
// tuple grows to 25 entries.
export const M5_ACTIVITY_TYPE_EXTENSIONS = [
  'regulatory_impact_detected',
  'regulatory_impact_resolved',
] as const;

export type M5ActivityTypeExtension = typeof M5_ACTIVITY_TYPE_EXTENSIONS[number];

/**
 * M5 widened activity-type union — 25 values
 * (M1a 7 + M1b 2 + M2 5 + M3 6 + M4 3 + M5 2 = 25 values).
 * Use this in M5 service modules when emitting contract_activity rows.
 */
export type M5ActivityType = M4ActivityType | M5ActivityTypeExtension;

// ------------------------------------------------------------
// 2. PUBLIC fn_ allowlist preservation (S2-21 mandatory)
// ------------------------------------------------------------
//
// Per Q1 (locked CONFIRM) — M5 introduces ZERO new PUBLIC SECURITY DEFINER
// fn_'s. All 15 M5 fn_'s have REVOKE ALL FROM PUBLIC + GRANT EXECUTE TO
// neondb_owner. Stage 4 enumerate-PUBLIC-grants must verify count = 5
// post-migration. M3's 5 PUBLIC fn_'s remain the canonical allowlist.
export const M3_PUBLIC_FN_ALLOWLIST = [
  'fn_signature_get_by_invitation_token',
  'fn_signature_sign',
  'fn_signature_decline',
  'fn_signer_qa_session_start',
  'fn_signer_qa_session_record_message',
] as const;

export type M3PublicFnName = typeof M3_PUBLIC_FN_ALLOWLIST[number];

/** M5 contributes ZERO new PUBLIC fn_ grants (Q1 locked CONFIRM). */
export const M5_PUBLIC_FN_ADDITIONS = [] as const;

// ------------------------------------------------------------
// 3. M5 permission codes (3 new — seeded in migration 046)
// ------------------------------------------------------------
//
// Q2 locked — 3 codes seeded + 12 role_permission grants. Without migration
// 046 every M5 endpoint 403s.
export const M5_NEW_PERMISSIONS = [
  'regulations.read',
  'regulations.manage',
  'config.manage',
] as const;

export type M5PermissionCode = typeof M5_NEW_PERMISSIONS[number];

// ------------------------------------------------------------
// 4. Sensitive-field marker (controller-only — not a DB column)
// ------------------------------------------------------------
//
// impact_payload is the AI-generated per-contract regulatory impact body,
// passed by the controller to fn_regulatory_impact_create_bulk. Pino redact
// at controller intercepts this key. Semantically covered by
// 'ai_prompt_payload' already in project.config.json sensitiveFields (M4
// precedent — same payload class). Per Q10 (locked NOT EXTEND),
// fn_audit_trigger redact list NOT extended. impact_payload is a fn
// parameter only — never a column.
export const M5_SENSITIVE_FIELD_MARKERS = [
  'impact_payload',
] as const;

export type M5SensitiveFieldName = typeof M5_SENSITIVE_FIELD_MARKERS[number];

// ------------------------------------------------------------
// 5. Shared enums backed by DB CHECK constraints
// ------------------------------------------------------------

/** regulation.regulation_type CHECK enum — closed canonical set. */
export type RegulationType =
  | 'federal_decree_law'
  | 'cabinet_resolution'
  | 'ministerial_decision'
  | 'free_zone_regulation'
  | 'circular'
  | 'guideline';

/** regulation.jurisdiction + regulator.jurisdiction CHECK enum. */
export type RegulationJurisdiction =
  | 'uae_federal'
  | 'dubai'
  | 'abu_dhabi'
  | 'sharjah'
  | 'difc'
  | 'adgm'
  | 'dmcc'
  | 'other';

/** regulation.status CHECK enum. */
export type RegulationStatus = 'active' | 'superseded' | 'repealed' | 'draft';

/** regulatory_update.severity CHECK enum. */
export type RegulatorySeverity = 'low' | 'medium' | 'high' | 'critical';

/** regulatory_impact.resolution_action CHECK enum. */
export type RegulatoryImpactResolutionAction =
  | 'amended'
  | 'waived'
  | 'out_of_scope'
  | 'pending';

/**
 * Computed status alias for FE consumers — derived from
 * regulatory_impact.resolved boolean + resolution_action. Not a DB column;
 * provided for UI convenience.
 */
export type RegulatoryImpactStatus = 'pending' | 'resolved';

// ------------------------------------------------------------
// 6. regulator entity (Q3 locked — shared lookup table)
// ------------------------------------------------------------

export interface Regulator {
  id: number;
  code: string;
  nameEn: string;
  nameAr: string | null;
  jurisdiction: RegulationJurisdiction | null;
  descriptionEn: string | null;
  descriptionAr: string | null;
  sourceUrl: string | null;
  displayOrder: number;
  isActive: boolean;
}

/**
 * Lighter shape embedded inside other entities' JSONB output
 * (regulation.issuer, regulatory_update.regulator).
 */
export interface RegulatorRef {
  id: number;
  code: string;
  nameEn: string;
  nameAr?: string | null;
}

// ------------------------------------------------------------
// 7. impact_category entity (Q5 locked — id BIGSERIAL + key UNIQUE)
// ------------------------------------------------------------

export interface ImpactCategory {
  id: number;
  key: string;
  nameEn: string;
  nameAr: string;
  descriptionEn: string | null;
  descriptionAr: string | null;
  icon: string;
  colour: string;
  /** Visibility flag for FE picker — separate from isActive soft-delete. */
  active: boolean;
  displayOrder: number;
  /** JSONB array of source name strings. */
  sources: string[];
  /** JSONB array of severity strings — default ["low","medium","high","critical"]. */
  severityScale: string[];
  /** Admin-authored AI guidance content; not user PII. */
  aiPromptContext: string | null;
  defaultClauseCategories: string[];
}

/**
 * Embedded shape inside fn_regulatory_update_list /
 * fn_regulatory_update_get_by_id. Lighter than full ImpactCategory.
 */
export interface ImpactCategoryRef {
  id: number;
  key: string;
  nameEn: string;
  nameAr: string;
  icon: string;
  colour: string;
}

/** Upsert DTO — maps to fn_impact_category_upsert parameters. */
export interface UpsertImpactCategoryDto {
  key: string;
  nameEn: string;
  /** AC-S15-03 — required. */
  nameAr: string;
  descriptionEn?: string | null;
  descriptionAr?: string | null;
  icon?: string;
  colour?: string;
  active?: boolean;
  displayOrder?: number;
  sources?: string[];
  /** AC-S15-04 — JSON array of strings. */
  severityScale?: string[];
  aiPromptContext?: string | null;
  defaultClauseCategories?: string[];
}

/** fn_impact_category_upsert return shape. */
export interface ImpactCategoryUpsertResult {
  id: number;
  key: string;
  createdOrUpdated: 'created' | 'updated';
}

/**
 * fn_impact_category_list response shape — AC-S14-01 returns no-pagination
 * envelope (small reference table, ~8-12 rows in production).
 */
export interface ImpactCategoryListResponse {
  data: ImpactCategory[];
}

export interface ImpactCategoryListQuery {
  includeInactive?: boolean;
}

// ------------------------------------------------------------
// 8. regulation entity (master library)
// ------------------------------------------------------------

export interface RegulationSupersededByItem {
  id: number;
  referenceCode: string;
  titleEn: string;
  titleAr: string | null;
  status: RegulationStatus;
  depth: number;
}

export interface RegulationListItem {
  id: number;
  referenceCode: string;
  titleEn: string;
  titleAr: string | null;
  issuer: RegulatorRef;
  regulationType: RegulationType;
  jurisdiction: RegulationJurisdiction | null;
  effectiveDate: string | null;
  /** Reference code of the superseder. */
  supersededByCode: string | null;
  status: RegulationStatus;
  isActive: boolean;
}

export interface Regulation {
  id: number;
  referenceCode: string;
  titleEn: string;
  titleAr: string | null;
  issuer: RegulatorRef;
  regulationType: RegulationType;
  jurisdiction: RegulationJurisdiction | null;
  effectiveDate: string | null;
  summaryEn: string | null;
  summaryAr: string | null;
  sourceUrl: string | null;
  /** Q4 locked — TEXT[]; junction normalisation deferred to M7+. */
  tags: string[];
  status: RegulationStatus;
  isActive: boolean;
  /** Recursive supersession chain (max 5 hops). Empty array when terminal. */
  supersededBy: RegulationSupersededByItem[];
}

export interface CreateRegulationDto {
  referenceCode: string;
  titleEn: string;
  titleAr?: string | null;
  /** Q3 locked — FK to regulator.id (BIGINT). */
  issuerId: number;
  regulationType: RegulationType;
  jurisdiction?: RegulationJurisdiction | null;
  effectiveDate?: string | null;
  summaryEn?: string | null;
  summaryAr?: string | null;
  sourceUrl?: string | null;
  /** Q4 — TEXT[] in DB; defaults to [] when omitted. */
  tags?: string[];
  /** Defaults to 'active' per AC-S3-06. */
  status?: RegulationStatus;
}

export interface UpdateRegulationDto {
  titleEn?: string;
  titleAr?: string | null;
  summaryEn?: string | null;
  summaryAr?: string | null;
  sourceUrl?: string | null;
  tags?: string[];
  status?: RegulationStatus;
  /** Auto-flips status to 'superseded' when set (AC-S4-02). */
  supersededById?: number | null;
  regulationType?: RegulationType;
  jurisdiction?: RegulationJurisdiction | null;
  effectiveDate?: string | null;
  issuerId?: number;
}

export interface RegulationCreateResult {
  id: number;
  referenceCode: string;
  createdAt: string;
}

export interface RegulationUpdateResult {
  id: number;
  updatedAt: string;
}

export interface RegulationDeleteResult {
  id: number;
  isActive: false;
}

export interface RegulationListResponse {
  data: RegulationListItem[];
  pagination: PaginationMeta;
}

export interface RegulationListQuery {
  page?: number;
  limit?: number;
  jurisdiction?: RegulationJurisdiction;
  regulationType?: RegulationType;
  /** Q3 locked — switched from issuer text to issuer_id BIGINT. */
  issuerId?: number;
  status?: RegulationStatus;
  /** ILIKE on titleEn / titleAr / referenceCode. FE debounced 300ms (T10). */
  search?: string;
}

// ------------------------------------------------------------
// 9. regulatory_update entity (radar feed)
// ------------------------------------------------------------

export interface RegulatoryImpactSummary {
  totalImpacts: number;
  resolvedCount: number;
  pendingCount: number;
  /** AC-S7-04 — null when totalImpacts == 0. */
  avgImpactScore: number | null;
}

export interface RegulatoryUpdateListItem {
  id: number;
  regulator: RegulatorRef;
  titleEn: string;
  titleAr: string | null;
  summaryEn: string | null;
  summaryAr: string | null;
  referenceNumber: string | null;
  publishedDate: string;
  effectiveDate: string | null;
  complianceDeadline: string | null;
  severity: RegulatorySeverity;
  sourceUrl: string | null;
  affectedClauseCategories: string[];
  category: ImpactCategoryRef | null;
  subSource: string | null;
}

export interface RegulatoryUpdate extends RegulatoryUpdateListItem {
  impactSummary: RegulatoryImpactSummary;
}

export interface CreateRegulatoryUpdateDto {
  /** Q3 locked — FK to regulator.id (BIGINT). */
  regulatorId: number;
  titleEn: string;
  titleAr?: string | null;
  summaryEn?: string | null;
  summaryAr?: string | null;
  referenceNumber?: string | null;
  publishedDate: string;
  effectiveDate?: string | null;
  complianceDeadline?: string | null;
  /** Defaults to 'medium' per AC-S8-07. */
  severity?: RegulatorySeverity;
  sourceUrl?: string | null;
  affectedClauseCategories?: string[];
  categoryId?: number | null;
  subSource?: string | null;
}

export interface UpdateRegulatoryUpdateDto {
  regulatorId?: number;
  titleEn?: string;
  titleAr?: string | null;
  summaryEn?: string | null;
  summaryAr?: string | null;
  referenceNumber?: string | null;
  /** AC-S9-02 floor guard — must not move below MIN(detected_at). */
  publishedDate?: string;
  effectiveDate?: string | null;
  complianceDeadline?: string | null;
  severity?: RegulatorySeverity;
  sourceUrl?: string | null;
  affectedClauseCategories?: string[];
  categoryId?: number | null;
  subSource?: string | null;
}

export interface RegulatoryUpdateCreateResult {
  id: number;
  createdAt: string;
}

export interface RegulatoryUpdateUpdateResult {
  id: number;
  updatedAt: string;
}

export interface RegulatoryUpdateDeleteResult {
  id: number;
  isActive: false;
  /** Count of regulatory_impact rows cascade-soft-deleted (AC-S10-02). */
  cascadedImpacts: number;
}

export interface RegulatoryUpdateListResponse {
  data: RegulatoryUpdateListItem[];
  pagination: PaginationMeta;
}

export interface RegulatoryUpdateListQuery {
  page?: number;
  limit?: number;
  regulatorId?: number;
  severity?: RegulatorySeverity;
  categoryId?: number;
  effectiveFrom?: string;
  effectiveTo?: string;
  /** Compliance-deadline cliff filter (FE radar). */
  complianceDeadlineMax?: string;
}

// ------------------------------------------------------------
// 10. regulatory_impact entity (G1 reconstituted)
// ------------------------------------------------------------

export interface RegulatoryImpactContractRef {
  id: number;
  contractNumber: string;
  titleEn: string;
}

export interface RegulatoryImpactRegulationRef {
  id: number;
  referenceCode: string;
  titleEn: string;
}

export interface RegulatoryImpactRegulatoryUpdateRef {
  id: number;
  titleEn: string;
  severity: RegulatorySeverity;
}

export interface RegulatoryImpact {
  id: number;
  contract: RegulatoryImpactContractRef;
  regulation: RegulatoryImpactRegulationRef;
  /**
   * Q7 — null when this is a structural impact (regulation only; no
   * specific regulatory_update event). Frontend renders `null` as
   * "Structural" badge.
   */
  regulatoryUpdate: RegulatoryImpactRegulatoryUpdateRef | null;
  impactScore: number | null;
  /** Q6 — short-form tag (radar tooltip). */
  impactNoteEn: string | null;
  impactNoteAr: string | null;
  /** Q6 — long-form AI executive summary. */
  impactSummaryEn: string | null;
  impactSummaryAr: string | null;
  detectedAt: string;
  resolved: boolean;
  resolutionAction: RegulatoryImpactResolutionAction | null;
  /** Q8 — admin-bounded free text. */
  resolutionNote: string | null;
}

/**
 * Per-contract payload entry passed to fn_regulatory_impact_create_bulk
 * via p_impact_payload JSONB. The wire shape is:
 *   { "<contractId>": ImpactPayloadEntry, ... }
 *
 * SENSITIVE — the payload object as a whole is the AI-generated content.
 * Pino redact at controller intercepts the 'impactPayload' key.
 */
export interface ImpactPayloadEntry {
  impactScore?: number | null;
  noteEn?: string | null;
  noteAr?: string | null;
  summaryEn?: string | null;
  summaryAr?: string | null;
}

export interface BulkDetectRegulatoryImpactDto {
  regulatoryUpdateId: number;
  regulationId: number;
  /** AC-S11-03 — must be non-empty. */
  contractIds: number[];
  /**
   * Per-contract payload keyed by contractId.toString().
   * SENSITIVE (AC-S11-07) — pino-redacted.
   */
  impactPayload: Record<string, ImpactPayloadEntry>;
}

export interface BulkDetectRegulatoryImpactResult {
  createdCount: number;
  /** AC-S11-02 — idempotent re-run skip count. */
  skippedDuplicateCount: number;
  impactIds: number[];
}

export interface ResolveRegulatoryImpactDto {
  resolutionAction: RegulatoryImpactResolutionAction;
  /** Q8 — admin-bounded free text; AC-S13-07 stored verbatim. */
  resolutionNote?: string | null;
}

export interface RegulatoryImpactResolveResult {
  id: number;
  /** AC-S13-02 — derived: resolution_action <> 'pending'. */
  resolved: boolean;
  resolutionAction: RegulatoryImpactResolutionAction;
  updatedAt: string;
}

export interface RegulatoryImpactListResponse {
  data: RegulatoryImpact[];
  pagination: PaginationMeta;
}

export interface RegulatoryImpactListQuery {
  page?: number;
  limit?: number;
  /** AC-S12-02 — at least one of contractId/regulationId/regulatoryUpdateId required. */
  contractId?: number;
  regulationId?: number;
  /** S2-18 NULL-safe equality on the column (IS NOT DISTINCT FROM). */
  regulatoryUpdateId?: number;
  resolved?: boolean;
}

// ------------------------------------------------------------
// 11. RESPONSE ENVELOPES (reuse M0 ApiResponse pattern)
// ------------------------------------------------------------

export type RegulationResponse = ApiResponse<Regulation>;
export type RegulationListEnvelope = ApiResponse<RegulationListResponse>;
export type RegulationCreateEnvelope = ApiResponse<RegulationCreateResult>;
export type RegulationUpdateEnvelope = ApiResponse<RegulationUpdateResult>;
export type RegulationDeleteEnvelope = ApiResponse<RegulationDeleteResult>;

export type RegulatoryUpdateResponse = ApiResponse<RegulatoryUpdate>;
export type RegulatoryUpdateListEnvelope = ApiResponse<RegulatoryUpdateListResponse>;
export type RegulatoryUpdateCreateEnvelope = ApiResponse<RegulatoryUpdateCreateResult>;
export type RegulatoryUpdateUpdateEnvelope = ApiResponse<RegulatoryUpdateUpdateResult>;
export type RegulatoryUpdateDeleteEnvelope = ApiResponse<RegulatoryUpdateDeleteResult>;

export type RegulatoryImpactListEnvelope = ApiResponse<RegulatoryImpactListResponse>;
export type RegulatoryImpactBulkDetectEnvelope = ApiResponse<BulkDetectRegulatoryImpactResult>;
export type RegulatoryImpactResolveEnvelope = ApiResponse<RegulatoryImpactResolveResult>;

export type ImpactCategoryListEnvelope = ApiResponse<ImpactCategoryListResponse>;
export type ImpactCategoryUpsertEnvelope = ApiResponse<ImpactCategoryUpsertResult>;

// ------------------------------------------------------------
// 12. AUTH MODE MARKER (api-contracts.json discriminator)
// ------------------------------------------------------------
//
// M5 introduces NO new auth modes. Q1 locked — zero new PUBLIC fn_'s; M5
// has no signed-token endpoints. All 15 M5 endpoints use authMode='jwt'.
export type ApiAuthMode = 'jwt' | 'signed-token' | 'none';

// ------------------------------------------------------------
// 13. Cross-module re-affirmation — Contract interface UNCHANGED in M5
// ------------------------------------------------------------
//
// Q11 locked NOT EXTEND — fn_contract_get_by_id projection unchanged.
export type { Contract };
