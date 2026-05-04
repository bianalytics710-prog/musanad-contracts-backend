// ============================================================
// M1a — Contracts: Core CRUD & Lifecycle — TypeScript Type Definitions
// Project: Musanad Contracts Hub (musanad-contracts)
// Derived from: db-design.md v1.0 (Agent 4) + requirements-analysis.json (Agent 2)
// Generator:    Agent 5 — Contract Generator (M1a slice)
//
// Stack targets:
//   - Backend: Express + TypeScript strict (regenerated to v2.6 default)
//   - Frontend: TanStack Start + React 19 + TS strict (Lovable preserve-stack)
//
// Conventions:
//   - JSONB output keys are camelCase (matches fn_ output) — TS keys mirror those
//   - Date/time fields are ISO-8601 strings — frontend uses formatDateTime
//     (Asia/Dubai per project.config.json) for display
//   - DTOs exclude id, createdAt, updatedAt, createdBy, updatedBy, isActive
//   - body_en / body_ar are SENSITIVE — pino-redacted on logging; the values
//     still appear in API response bodies (decrypted clients only). The DB-
//     side audit redaction is handled by migration 004 (extends fn_audit_trigger).
//   - No `any`. Where flexible JSON is needed: Record<string, unknown>
//
// Do not edit manually — regenerate via Agent 5 if DB design changes.
// ============================================================

// ------------------------------------------------------------
// 1. Imports from M0 — DO NOT redeclare these locally
// ------------------------------------------------------------

import type {
  ApiResponse,
  ErrorResponse,
  Paginated,
  PaginationMeta,
  AuditColumns,
  JwtPayload,
  AuthUser,
  RoleRef,
  SensitiveFieldName as M0SensitiveFieldName,
} from './api.types';

export type {
  ApiResponse,
  ErrorResponse,
  Paginated,
  PaginationMeta,
  AuditColumns,
  JwtPayload,
  AuthUser,
  RoleRef,
};

// ------------------------------------------------------------
// 2. SENSITIVE_FIELD_NAMES extension (M1a appends body_en + body_ar)
// ------------------------------------------------------------

/**
 * M1a extends the M0 SensitiveFieldName union with the contract-version
 * body fields. The runtime list lives in the migration 004 redact array
 * inside fn_audit_trigger; this TypeScript-side union exists so pino
 * redaction config in BE Implementation can reference both M0 names AND
 * the M1a additions through a single union.
 *
 * Usage in pino redaction:
 *   const REDACT_PATHS: readonly SensitiveFieldName[] = [
 *     ...SENSITIVE_FIELD_NAMES,
 *     'body_en', 'body_ar',
 *   ];
 *
 * Note: 'contract_body' already exists in M0's SENSITIVE_FIELD_NAMES, but
 * the audit trigger redacts on LITERAL key match. The Contract entity uses
 * separate body_en / body_ar columns, so both names must be in the redact
 * array for fn_audit_trigger to scrub them out of audit_log.new_values.
 */
export const M1A_SENSITIVE_FIELD_EXTENSIONS = ['body_en', 'body_ar'] as const;
export type M1aSensitiveFieldName = (typeof M1A_SENSITIVE_FIELD_EXTENSIONS)[number];
export type SensitiveFieldName = M0SensitiveFieldName | M1aSensitiveFieldName;

// ------------------------------------------------------------
// 3. Enum union types (lookup-style values; CHECK-constrained in DB)
// ------------------------------------------------------------

/** 14-state workflow per requirements-analysis.json. M1a only sets/reads — full state machine is M2. */
export type ContractStatus =
  | 'draft'
  | 'in_review'
  | 'approved'
  | 'awaiting_signature_employer'
  | 'awaiting_signature_counterparty'
  | 'fully_signed'
  | 'active'
  | 'expiring_soon'
  | 'expired'
  | 'amended'
  | 'renewed'
  | 'terminated'
  | 'rejected'
  | 'resubmission_requested';

export type ContractLanguage = 'en' | 'ar' | 'bilingual';

export type GoverningLaw =
  | 'uae_federal'
  | 'dubai'
  | 'abu_dhabi'
  | 'sharjah'
  | 'difc'
  | 'adgm'
  | 'english'
  | 'other';

export type RelationshipType =
  | 'amendment'
  | 'renewal'
  | 'extension'
  | 'superseded'
  | 'sow_under_msa';

export type ActivityType =
  | 'created'
  | 'updated'
  | 'status_changed'
  | 'version_created'
  | 'tagged'
  | 'soft_deleted'
  | 'restored';

/**
 * Contract-domain role keys (created in M1a CMSW-1). M0's existing roles
 * (Super Admin / Admin / User) are NOT included here — they live in the
 * M0 role-name space. RLS policies in M1a treat platform_admin /
 * legal_counsel / executive as "see-all" privileged roles.
 */
export type ContractRoleKey =
  | 'platform_admin'
  | 'legal_counsel'
  | 'contract_drafter'
  | 'contract_approver'
  | 'contract_approver_2'
  | 'contract_recipient'
  | 'executive';

/** M1a permission codes inserted by CMSW-2. */
export type ContractPermissionCode =
  | 'contract.read.all'
  | 'contract.read.department'
  | 'contract.read.own'
  | 'contract.draft'
  | 'contract.edit'
  | 'contract.delete'
  | 'contract.export'
  | 'contract.tag.manage'
  | 'contract.status.update';

// ------------------------------------------------------------
// 4. Sub-shapes (used inside Contract, ContractVersion, ContractActivity)
// ------------------------------------------------------------

/**
 * Lightweight user reference returned inside fn_contract_get_by_id /
 * fn_contract_version_list / fn_contract_activity_list.
 */
export interface UserRef {
  id: number;
  firstName: string;
  lastName: string;
}

// ------------------------------------------------------------
// 5. Contract entity types
// ------------------------------------------------------------

/**
 * Contract — derived from fn_contract_get_by_id JSONB output.
 *
 * NB: bodyEn / bodyAr appear in this type but are SENSITIVE.
 *     - Pino logs MUST redact them.
 *     - audit_log entries auto-redact via migration 004.
 *     - fn_contract_list does NOT include them (AC-S1-08).
 */
export interface Contract {
  id: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  contractType: string;
  templateId: number | null;
  status: ContractStatus;
  language: ContractLanguage;
  ourPartyId: number | null;
  counterpartyId: number | null;
  valueAed: number | null;
  currency: string;
  startDate: string | null;
  endDate: string | null;
  signedAt: string | null;
  expiryNoticeDays: number;
  emirate: string | null;
  governingLaw: GoverningLaw | null;
  jurisdictionCourt: string | null;
  parentContractId: number | null;
  relationshipType: RelationshipType | null;
  /** SENSITIVE — pino-redact. */
  bodyEn: string | null;
  /** SENSITIVE — pino-redact. */
  bodyAr: string | null;
  currentVersion: number;
  draftedBy: UserRef | null;
  reviewedBy: UserRef | null;
  approvedBy: UserRef | null;
  tags: string[];
  attachmentCount: number;
  commentCount: number;

  // ---- M1c additive extension (Codex BE round-1 finding H1, migration 022) ----
  // fn_contract_get_by_id projection extended to surface the 4 import-trace
  // fields in camelCase. Always present in responses; null when the contract
  // was not bulk-imported. Round-trip symmetry with ContractListItem (which
  // carries 3 of these — list rows omit importFilename for payload weight).
  /** M1c addition. import_batch.id this contract belongs to (or null). */
  importBatchId: number | null;
  /** M1c addition. Original uploaded filename (or null when not bulk-imported). */
  importFilename: string | null;
  /** M1c addition. 0..100 AI confidence (or null when not extracted). */
  importConfidence: number | null;
  /** M1c addition. Array of human-readable warnings (or null). */
  importWarnings: string[] | null;

  createdAt: string;
  updatedAt: string;
}

/**
 * ContractListItem — lighter shape returned inside fn_contract_list[].data[i].
 * Excludes body_en / body_ar (AC-S1-08).
 */
export interface ContractListItem {
  id: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  contractType: string;
  status: ContractStatus;
  valueAed: number | null;
  currency: string;
  startDate: string | null;
  endDate: string | null;
  counterpartyId: number | null;
  ourPartyId: number | null;
  tags: string[];
  currentVersion: number;
  createdAt: string;
  updatedAt: string;

  // ---- M1c additive extension (AE-1 / AE-2) ----
  // fn_contract_list 18-param signature surfaces 3 new fields per row.
  // Always present in responses; null when contract was not bulk-imported.
  /** M1c addition. import_batch.id this contract belongs to (or null). */
  importBatchId: number | null;
  /** M1c addition. 0..100 AI confidence (or null when not extracted). */
  importConfidence: number | null;
  /** M1c addition. Array of human-readable warnings (or null). */
  importWarnings: string[] | null;
}

// ------------------------------------------------------------
// 6. ContractTag (junction table — typically not exposed; included for completeness)
// ------------------------------------------------------------

export interface ContractTag {
  id: number;
  contractId: number;
  tag: string;
  createdAt: string;
  createdBy: number | null;
  isActive: boolean;
}

// ------------------------------------------------------------
// 7. ContractVersion entity types
// ------------------------------------------------------------

export interface ContractVersion {
  id: number;
  versionNumber: number;
  /** SENSITIVE — pino-redact. */
  bodyEn: string | null;
  /** SENSITIVE — pino-redact. */
  bodyAr: string | null;
  diffSummary: string | null;
  changeNote: string | null;
  changedBy: UserRef | null;
  createdAt: string;
}

/**
 * Return shape of fn_contract_version_create.
 */
export interface ContractVersionCreated {
  id: number;
  versionNumber: number;
  contractId: number;
  createdAt: string;
}

// ------------------------------------------------------------
// 8. ContractActivity entity types
// ------------------------------------------------------------

export interface ContractActivity {
  id: number;
  activityType: ActivityType;
  actor: UserRef | null;
  descriptionEn: string | null;
  descriptionAr: string | null;
  metadata: ContractActivityMetadata | null;
  createdAt: string;
}

/**
 * Discriminated metadata payload by activityType.
 */
export type ContractActivityMetadata =
  | { fromStatus: ContractStatus; toStatus: ContractStatus; reason?: string | null }
  | { versionNumber: number }
  | { added: string[]; removed: string[] }
  | Record<string, unknown>;

// ------------------------------------------------------------
// 9. Request DTOs — shapes the FE SENDS to the BE
// ------------------------------------------------------------

export interface CreateContractDto {
  titleEn: string;
  titleAr?: string | null;
  contractType: string;
  templateId?: number | null;
  language?: ContractLanguage;
  ourPartyId?: number | null;
  counterpartyId?: number | null;
  valueAed?: number | null;
  currency?: string;
  startDate?: string | null;
  endDate?: string | null;
  expiryNoticeDays?: number;
  emirate?: string | null;
  governingLaw?: GoverningLaw | null;
  jurisdictionCourt?: string | null;
  parentContractId?: number | null;
  relationshipType?: RelationshipType | null;
  bodyEn?: string | null;
  bodyAr?: string | null;
  tags?: string[];

  // ---- M1c additive extension (Q3-OI-A / AE-1 / OI-2) ----
  // Bulk-import flow per AC-S5-08, AC-S7-04 calls POST /api/v1/contracts
  // with these extra keys. All are optional and target M1a-shipped columns
  // on contract — additive at the runtime Zod schema level (no fn_ change).
  /** M1c addition. import_batch.id this insert belongs to. */
  importBatchId?: number | null;
  /** M1c addition. Original uploaded filename — captured on contract.import_filename. */
  importFilename?: string | null;
  /** M1c addition. 0..100 AI extraction confidence. */
  importConfidence?: number | null;
  /** M1c addition. Array of human-readable AI warnings. */
  importWarnings?: string[] | null;
}

export interface UpdateContractDto {
  titleEn?: string;
  titleAr?: string | null;
  contractType?: string;
  templateId?: number | null;
  language?: ContractLanguage;
  ourPartyId?: number | null;
  counterpartyId?: number | null;
  valueAed?: number | null;
  currency?: string;
  startDate?: string | null;
  endDate?: string | null;
  expiryNoticeDays?: number;
  emirate?: string | null;
  governingLaw?: GoverningLaw | null;
  jurisdictionCourt?: string | null;
  parentContractId?: number | null;
  relationshipType?: RelationshipType | null;
  bodyEn?: string | null;
  bodyAr?: string | null;
  // tags NOT updated here — use PUT /contracts/:id/tags
  // status NOT updatable here — use PATCH /contracts/:id/status
}

export interface UpdateContractStatusDto {
  newStatus: ContractStatus;
  reason?: string | null;
}

export interface SetContractTagsDto {
  tags: string[];
}

export interface CreateContractVersionDto {
  bodyEn?: string | null;
  bodyAr?: string | null;
  diffSummary?: string | null;
  changeNote: string;
}

// ------------------------------------------------------------
// 10. Query parameter types
// ------------------------------------------------------------

export interface ContractListQuery {
  page?: number;
  limit?: number;
  status?: ContractStatus;
  contractType?: string;
  counterpartyId?: number;
  draftedBy?: number;
  approvedBy?: number;
  startDateFrom?: string;
  startDateTo?: string;
  endDateFrom?: string;
  endDateTo?: string;
  /** AND-semantics — all tags must match. */
  tags?: string[];
  search?: string;

  // ---- M1c additive extension (AE-1) ----
  // fn_contract_list 18-param signature accepts 3 new optional filter
  // params. Existing call sites that omit them are unaffected.
  /** M1c addition. Filter to a single import_batch (S4 admin drill-down). AC-S4-05. */
  importBatchId?: number;
  /** M1c addition. Lower bound on contract.import_confidence — range 0..100 (S6). AC-S6-01. */
  importConfidenceMin?: number;
  /** M1c addition. Upper bound on contract.import_confidence — range 0..100 (S6). AC-S6-01. */
  importConfidenceMax?: number;
}

export interface ContractVersionListQuery {
  page?: number;
  limit?: number;
}

export interface ContractActivityListQuery {
  page?: number;
  limit?: number;
  activityType?: ActivityType;
}

// ------------------------------------------------------------
// 11. Response payload types
// ------------------------------------------------------------

export type ContractListResponse = Paginated<ContractListItem>;

export type ContractResponse = Contract;

export type CreateContractResponse = Contract;

export type UpdateContractResponse = Contract;

export interface DeleteContractResponse {
  success: true;
  id: number;
  message: string;
}

export interface UpdateContractStatusResponse {
  id: number;
  fromStatus: ContractStatus;
  toStatus: ContractStatus;
  changedAt: string;
}

export interface ContractTreeNode {
  id: number;
  contractNumber: string;
  titleEn: string;
  status: ContractStatus;
  parentContractId: number | null;
  relationshipType: RelationshipType | null;
  createdAt: string;
  depth: number;
}

export interface ContractTreeResponse {
  rootId: number;
  tree: ContractTreeNode[];
  currentNode: number;
  truncated: boolean;
}

export interface SetContractTagsResponse {
  id: number;
  tags: string[];
}

export type ContractVersionListResponse = Paginated<ContractVersion>;

export type CreateContractVersionResponse = ContractVersionCreated;

export type ContractActivityListResponse = Paginated<ContractActivity>;

// ------------------------------------------------------------
// 12. Internal fn_ helper return shapes (BE-side only — not exposed via API)
// ------------------------------------------------------------

/**
 * fn_contract_activity_create return shape.
 * @internal — invoked only from triggers; not exposed via HTTP.
 */
export interface ContractActivityCreated {
  id: number;
}

// ------------------------------------------------------------
// 13. Type guards / discriminator helpers
// ------------------------------------------------------------

export function isStatusChangedMetadata(
  m: ContractActivityMetadata | null,
): m is { fromStatus: ContractStatus; toStatus: ContractStatus; reason?: string | null } {
  return m !== null && typeof m === 'object' && 'fromStatus' in m && 'toStatus' in m;
}

export function isVersionCreatedMetadata(
  m: ContractActivityMetadata | null,
): m is { versionNumber: number } {
  return m !== null && typeof m === 'object' && 'versionNumber' in m && !('fromStatus' in m);
}

export function isTaggedMetadata(
  m: ContractActivityMetadata | null,
): m is { added: string[]; removed: string[] } {
  return m !== null && typeof m === 'object' && 'added' in m && 'removed' in m;
}
