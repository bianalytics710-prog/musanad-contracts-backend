// ============================================================
// M8 — Internal Signal Data Path (CR-A2) — TypeScript Type Definitions
//
// Mirrors workspace types.ts (Agent 5 contract output) — byte-for-byte for
// every JSONB shape returned by the 4 fn_'s in db-design.md §5. Imports
// PaginationMeta from M0 + Severity / SignalKind / DataClassification /
// OsintSignal / OsintSignalUpsertPayload from M7's osint.types.ts (M7 ground
// truth — NOT redefined here).
//
// Q-DA lock summary (decisions/M8.json gateClosedAt 2026-05-09T21:50Z):
//   - Q-DA1 = DEFER osint_signal CHECK extension                  (no impact on types)
//   - Q-DA2 = PG_NOTIFY-ONLY (no signal_event table)              (no impact on types)
//   - Q-DA3 = HARDCODED resolve permission mapping in fn body     (no impact on types)
//   - Q-DA4 = ALWAYS-MANUAL resolution                            (no impact on types)
//   - Q-DA5 = RELATIVE seed back-dating (now() - interval 'N')     (no impact on types)
//   - Q-DA6 = ADD osint_signal.metadata JSONB column (Impl A)      → InternalSignalRow.metadata
// ============================================================

import type { PaginationMeta } from './api.types';
import type {
  Severity,
  SignalKind,
  DataClassification,
  OsintSignalUpsertPayload,
} from './osint.types';

// ============================================================
// 1. String unions
// ============================================================

/**
 * The 8 SOT-sealed internal signal sub-types. Maps 1:1 to the
 * `internal_signal_kind.signal_type` CHECK enum (db-design.md §1.1) AND to
 * `osint_signal.signal_kind_subtype` for rows where `kind = 'internal'`.
 */
export type InternalSignalType =
  | 'milestone_slippage'
  | 'sla_breach'
  | 'payment_delay'
  | 'invoice_dispute'
  | 'vendor_incident'
  | 'ics_incident'
  | 'icv_status_change'
  | 'certificate_expiry';

/**
 * Resolution kind enum — closed list per db-design.md §5.2 step 5.
 * `fn_internal_signal_resolve` raises `22023 'Invalid resolution kind'` for any
 * value outside this set.
 */
export type SignalResolutionKind =
  | 'cleared'
  | 'superseded'
  | 'mitigated'
  | 'false_positive';

/**
 * Status filter for `GET /api/v1/internal-signals?status=...`. Maps to
 * `metadata.resolvedAt IS NULL` (open) / `IS NOT NULL` (resolved) per
 * db-design.md §5.4.1. `'all'` is the controller-side default (no predicate).
 */
export type InternalSignalStatusFilter = 'open' | 'resolved' | 'all';

// Re-export reused M7 types as a convenience for callers that only import
// from M8.
export type { Severity, SignalKind, DataClassification } from './osint.types';

// ============================================================
// 2. InternalSignalKind (catalogue entity)
// ============================================================

/**
 * Shape of the `parameter_schema` JSONB column on `internal_signal_kind`.
 * Consumed by `fn_internal_signal_ingest` for required-field enforcement
 * (db-design.md §5.1 step 5).
 */
export interface InternalSignalParameterSchema {
  required: string[];
  optional: string[];
}

/**
 * `internal_signal_kind` row as projected by `fn_internal_signal_kind_list`
 * (db-design.md §5.3). Bare-array shape per M7 `fn_source_health_list`
 * precedent — there is NO surrounding `{ data, pagination }` envelope for
 * this fn.
 */
export interface InternalSignalKind {
  id: number;
  signalType: InternalSignalType;
  displayName: string;
  displayNameAr: string;
  description: string | null;
  parameterSchema: InternalSignalParameterSchema;
  defaultSeverity: Severity;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
}

// ============================================================
// 3. Internal Signal — read shape
// ============================================================

/**
 * Resolution-lifecycle JSONB sub-object stored on `osint_signal.metadata`
 * (Q-DA6 lock = ADD column). Written ONLY by `fn_internal_signal_resolve`
 * (db-design.md §5.2 Implementation A step 8).
 */
export interface InternalSignalMetadata {
  resolvedAt: string;
  resolvedBy: number | null;
  resolutionKind: SignalResolutionKind;
  resolutionNote: string | null;
}

/**
 * Internal signal row as projected by `fn_internal_signal_list` (db-design.md
 * §5.4 JSONB output). Narrows the M7 OsintSignal contract to `kind='internal'`
 * AND adds the CR-A2-specific projections (signalType / metadata / flat
 * resolvedAt / resolvedBy / resolutionKind).
 */
export interface InternalSignalRow {
  id: number;
  tenantId: string;
  signalType: InternalSignalType;
  kind: 'internal';
  title: string;
  summary: string | null;
  severity: Severity;
  confidence: number;
  fetchedAt: string;
  eventDate: string | null;
  sourceId: 'internal:harness';
  sourceReliability: number;
  /**
   * Full original ingest payload (signalType, contractId/vendorId,
   * milestoneRef/invoiceRef/etc.).
   */
  rawPayload: Record<string, unknown>;
  /**
   * Resolution + future-extension JSONB. Empty object `{}` for unresolved
   * signals.
   */
  metadata: Record<string, unknown>;
  /** Convenience flat projection of `metadata.resolvedAt`. NULL when open. */
  resolvedAt: string | null;
  /** Convenience flat projection of `metadata.resolvedBy`. NULL when open. */
  resolvedBy: number | null;
  /** Convenience flat projection of `metadata.resolutionKind`. NULL when open. */
  resolutionKind: SignalResolutionKind | null;
  createdAt: string;
}

// ============================================================
// 4. Ingest contract — POST /api/v1/admin/internal-signals
// ============================================================

/**
 * Caller payload for `fn_internal_signal_ingest(p_payload JSONB)`. Required
 * keys: signalType + observedAt. Conditional keys per the catalogue row's
 * `parameterSchema.required[]`.
 *
 * Severity override is OPTIONAL — fn_internal_signal_ingest defaults to the
 * catalogue row's `defaultSeverity` (db-design.md §5.1 step 8).
 */
export interface InternalSignalIngestPayload {
  signalType: InternalSignalType;
  /** ISO-8601 UTC timestamp (e.g. '2026-04-15T10:00:00Z'). */
  observedAt: string;
  contractId?: number;
  vendorId?: number;
  milestoneRef?: string;
  invoiceRef?: string;
  daysOverdue?: number;
  /** Free-form per-signal-type input — projected into raw_payload. */
  severityCalcInput?: Record<string, unknown>;
  /** Optional override of the catalogue defaultSeverity. */
  severity?: Severity;
  /** Optional. Defaults to 'demo'. */
  dataClassification?: DataClassification;
}

/**
 * Response shape from `fn_internal_signal_ingest` (db-design.md §5.1 step 11).
 * `inserted=true` means a new row was written; `inserted=false` means the
 * dedup_hash UNIQUE(tenant_id, dedup_hash) suppressed the insert (idempotent
 * AC-S2-02).
 */
export interface InternalSignalIngestResponse {
  signalId: number;
  inserted: boolean;
  dedupHashHit: boolean;
  signalKindSubtype: InternalSignalType;
}

// ============================================================
// 5. Resolve contract — POST /api/v1/internal-signals/:id/resolve
// ============================================================

export interface InternalSignalResolvePayload {
  resolutionKind: SignalResolutionKind;
  resolutionNote?: string;
}

/**
 * Response from `fn_internal_signal_resolve` (db-design.md §5.2 step 10).
 * Idempotent — re-resolve returns the existing values without re-emitting the
 * pg_notify (AC-S5-03).
 */
export interface InternalSignalResolveResponse {
  signalId: number;
  resolvedAt: string;
  resolvedBy: number | null;
  resolutionKind?: SignalResolutionKind;
  /** TRUE on idempotent re-resolve; FALSE on first-resolve. */
  idempotent?: boolean;
}

// ============================================================
// 6. List contracts — GET /api/v1/internal-signals
// ============================================================

/**
 * Query params for `GET /api/v1/internal-signals` — maps directly to
 * `fn_internal_signal_list(p_filter JSONB)` (db-design.md §5.4.1 filter map).
 */
export interface InternalSignalListFilter {
  signalType?: InternalSignalType;
  contractId?: number;
  vendorId?: number;
  /** ISO-8601 UTC timestamp lower bound for `fetched_at`. */
  since?: string;
  /**
   * Resolution-state filter. 'all' or omitted → no predicate. 'open' →
   * `metadata.resolvedAt IS NULL`. 'resolved' →
   * `metadata.resolvedAt IS NOT NULL`.
   */
  status?: InternalSignalStatusFilter;
  page?: number;
  /** Default 20; clamped to 100 server-side. */
  limit?: number;
}

/**
 * Paginated list response for `GET /api/v1/internal-signals` (db-design.md
 * §5.4 JSONB output).
 */
export interface InternalSignalListResponse {
  data: InternalSignalRow[];
  pagination: PaginationMeta;
}

/**
 * Bare-array response for `GET /api/v1/admin/internal-signal-kinds`. NO
 * pagination wrapper — bounded set (8 rows per tenant).
 */
export type InternalSignalKindListResponse = InternalSignalKind[];

// ============================================================
// 7. pg_notify channel payload (Q-DA2 = PG_NOTIFY-ONLY)
// ============================================================

/**
 * Payload emitted by `fn_internal_signal_resolve` (db-design.md §5.2 step 9).
 * NOT emitted on idempotent re-resolve (AC-S5-03).
 */
export interface InternalSignalResolvedNotification {
  signalId: number;
  tenantId: string;
  signalKindSubtype: InternalSignalType;
  resolutionKind: SignalResolutionKind;
  resolvedBy: number | null;
  resolvedAt: string;
}

// ============================================================
// 8. S2-19 LOCK — Internal upsert payload bridge
//
// `fn_internal_signal_ingest` constructs an OsintSignalUpsertPayload (M7
// contract) inside its body and delegates to `fn_osint_signal_upsert`. We
// re-export the M7 type here for callers that need to reason about the
// constructed payload — but the shape is M7-owned and MUST NOT drift.
// ============================================================

export type InternalSignalConstructedUpsertPayload = OsintSignalUpsertPayload;
