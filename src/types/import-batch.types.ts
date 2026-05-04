// ============================================================
// M1c — Bulk & Manual Import — TypeScript types (BE)
// Project: Musanad Contracts Hub (musanad-contracts)
// Module:  M1c (third sub-module of M1; M0 + M1a + M1b shipped)
//
// Mirrors C:/.../.claude/workspace/current-module/types.ts (Agent 5).
// All keys camelCase to match fn_'s jsonb_build_object output (db-design.md
// §3 + §4). Audit columns (createdBy/updatedBy/isActive) intentionally NOT
// surfaced — fn_import_batch_get_by_id projects only user-facing fields.
//
// Do not edit manually — extend additively if DB design changes.
// ============================================================

import type { Paginated } from './api.types';
import type {
  ContractLanguage,
  GoverningLaw,
  RelationshipType,
  UserRef,
} from './contracts.types';

// ------------------------------------------------------------
// 1. Lifecycle enums
// ------------------------------------------------------------

/**
 * 4-value lifecycle enum for import_batch.status (DB CHECK constraint).
 *
 * Allowed transitions (AC-S2-02):
 *   in_progress -> paused | completed | cancelled
 *   paused      -> in_progress | completed | cancelled
 *   completed   -> (terminal)
 *   cancelled   -> (terminal)
 */
export type ImportBatchStatus =
  | 'in_progress'
  | 'paused'
  | 'completed'
  | 'cancelled';

/**
 * 3-value enum for import_batch.config.statusMode. Lives inside JSONB —
 * not a DB column. Validated server-side inside fn_import_batch_create
 * and mirrored at the BE Zod layer.
 */
export type ImportBatchStatusMode = 'active' | 'draft' | 'auto';

// ------------------------------------------------------------
// 2. Config sub-shape
// ------------------------------------------------------------

/**
 * ImportBatchConfig — JSONB payload stored on import_batch.config.
 * { contractType?: string, statusMode: 'active'|'draft'|'auto',
 *   defaultCounterpartyId?: number }
 */
export interface ImportBatchConfig {
  contractType?: string;
  statusMode: ImportBatchStatusMode;
  defaultCounterpartyId?: number;
}

// ------------------------------------------------------------
// 3. Core entity types
// ------------------------------------------------------------

/**
 * ImportBatch — derived from fn_import_batch_get_by_id JSONB output
 * (db-design.md §4.2). initiatedBy is hydrated as a UserRef
 * (AC-S4-04) via fn_user_get_by_id.
 */
export interface ImportBatch {
  id: number;
  initiatedBy: UserRef;
  config: ImportBatchConfig;
  totalFiles: number;
  // 5 running counters — chk_import_batch_counter_sum invariant:
  //   sum(autoSaved..errored) <= totalFiles
  autoSaved: number;
  reviewQueue: number;
  manualEntry: number;
  duplicatesSkipped: number;
  errored: number;
  status: ImportBatchStatus;
  startedAt: string;
  completedAt: string | null;
  createdAt: string;
  updatedAt: string;
}

/**
 * ImportBatchListItem — derived from fn_import_batch_list[i] JSONB output.
 * Lighter than ImportBatch (initiatedBy is a raw bigint user id, not UserRef;
 * createdAt + updatedAt omitted) per db-design.md §4.1.
 */
export interface ImportBatchListItem {
  id: number;
  /** Raw bigint user id — list view stays lean. Drill-down hydrates UserRef. */
  initiatedBy: number;
  totalFiles: number;
  autoSaved: number;
  reviewQueue: number;
  manualEntry: number;
  duplicatesSkipped: number;
  errored: number;
  status: ImportBatchStatus;
  config: ImportBatchConfig;
  startedAt: string;
  completedAt: string | null;
}

// ------------------------------------------------------------
// 4. DTOs (controller inputs)
// ------------------------------------------------------------

/** Body of POST /api/v1/import-batches (S1). */
export interface CreateImportBatchDto {
  totalFiles: number;
  config?: ImportBatchConfig;
}

/**
 * Body of PATCH /api/v1/import-batches/:id (S2). Counter deltas are SIGNED
 * integers (negative allowed iff result remains >= 0 — AC-S2-04 underflow
 * guard). Absent fields default to 0 at the fn_ layer.
 */
export interface UpdateImportBatchDto {
  status?: ImportBatchStatus;
  autoSavedDelta?: number;
  reviewQueueDelta?: number;
  manualEntryDelta?: number;
  duplicatesSkippedDelta?: number;
  /** OI-6 5th counter — lets the batch reach 'completed' when files fail. */
  erroredDelta?: number;
}

/** Query string for GET /api/v1/import-batches (S3). */
export interface ImportBatchListQuery {
  page?: number;
  limit?: number;
  status?: ImportBatchStatus;
  initiatedBy?: number;
}

// ------------------------------------------------------------
// 5. Response shapes
// ------------------------------------------------------------

export type ImportBatchListResponse = Paginated<ImportBatchListItem>;
export type ImportBatchResponse = ImportBatch;
export type CreateImportBatchResponse = ImportBatch;
export type UpdateImportBatchResponse = ImportBatch;

// ------------------------------------------------------------
// 6. AI extract-contract-bulk stub (S8) — frozen DTO contract for M4
// ------------------------------------------------------------
//
// Per HITL Gate 2 / HQ2: M1c ships POST /api/v1/ai/extract-contract-bulk
// as a controller-only STUB (no fn_, no DB persistence). M4 will replace
// the controller body WITHOUT changing the route, auth, request DTO, or
// response DTO (AC-S8-07). The shapes below are FROZEN.

/**
 * Body of POST /api/v1/ai/extract-contract-bulk (S8).
 *
 * extractedText is treated as `ai_prompt_payload` per project.config.json
 * sensitiveFields and pino-redacted in any log line (AC-S8-06).
 */
export interface ExtractContractBulkRequest {
  filename: string;
  /** File size in bytes (informational — not used by stub but locked for M4). */
  fileSize: number;
  /**
   * Already client-side-extracted text (mammoth/pdfjs in browser per
   * AC-S5-02). Min 50 characters (AC-S8-03).
   */
  extractedText: string;
  /** import_batch.id this file belongs to. */
  batchId: number;
}

/**
 * Response body of POST /api/v1/ai/extract-contract-bulk (S8).
 *
 * Locked DTO: M1a CreateContractDto fields (all optional — AI may not
 * detect every field) + importConfidence (0..100, REQUIRED) +
 * importWarnings (REQUIRED) + detectedDuplicateContractNumber (optional).
 */
export interface ExtractContractBulkResponse {
  // ---- M1a CreateContractDto fields (all optional in the AI response) ----
  titleEn?: string;
  titleAr?: string;
  contractType?: string;
  templateId?: number;
  language?: ContractLanguage;
  ourPartyId?: number;
  counterpartyId?: number;
  valueAed?: number;
  currency?: string;
  startDate?: string;
  endDate?: string;
  expiryNoticeDays?: number;
  emirate?: string;
  governingLaw?: GoverningLaw;
  jurisdictionCourt?: string;
  parentContractId?: number;
  relationshipType?: RelationshipType;
  bodyEn?: string;
  bodyAr?: string;
  tags?: string[];

  // ---- M1c-specific extraction metadata (REQUIRED) ----

  /**
   * AI extraction confidence — integer 0..100. Routes the per-file result
   * via IMPORT_CONFIDENCE_THRESHOLDS in the FE bulk-import flow.
   */
  importConfidence: number;

  /**
   * Optional list of human-readable warnings produced during extraction.
   * Surfaced in the review queue per AC-S6-02 / AC-S6-08. Null when no
   * warnings apply.
   */
  importWarnings: string[] | null;

  /**
   * Optional contract number the AI detected on the document. When present,
   * the FE pre-checks against existing active contracts; matching rows are
   * skipped (AC-S5-09). Null when AI did not detect a contract number.
   */
  detectedDuplicateContractNumber?: string | null;
}

// ------------------------------------------------------------
// 7. Confidence thresholds (Q5 / AC-S5-05)
// ------------------------------------------------------------

/**
 * Confidence thresholds used to route AI-extraction results in the bulk-
 * import flow (AC-S5-05). Single source of truth — consumed by FE routing
 * AND the future M4 controller (when it replaces the stub).
 *
 * Routing rule:
 *   importConfidence >= IMPORT_CONFIDENCE_THRESHOLDS.high     -> auto-save track
 *   importConfidence in [medium, high)                        -> review queue
 *   importConfidence <  IMPORT_CONFIDENCE_THRESHOLDS.medium   -> manual entry
 */
export const IMPORT_CONFIDENCE_THRESHOLDS = {
  high: 80,
  medium: 50,
  low: 0,
} as const;

// ------------------------------------------------------------
// 8. New permission codes introduced by M1c (migration 018)
// ------------------------------------------------------------

export const M1C_NEW_PERMISSIONS = ['import.run', 'import.review'] as const;
export type M1cPermissionCode = (typeof M1C_NEW_PERMISSIONS)[number];
