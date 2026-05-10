/**
 * CR-C — Audit Hash Chain types (S1, S2, S3, S4).
 *
 * Mirrors the workspace types.ts §2 contract (workspace artifact lives outside
 * BE tsconfig include root — re-implementation is the standard pattern, see
 * party-graph.types.ts).
 *
 * AuditPayload is the canonical-payload contract — single source of truth for
 * the bytes hashed by both `audit-canonical.util.ts` (BE) and
 * `fn_audit_log_canonicalize` (PG) per Annex D.7.1 footnote.
 */
import type { ApiResponse } from './api.types';

/** audit_log.action CHECK enum (M0 baseline). */
export type AuditAction = 'INSERT' | 'UPDATE' | 'DELETE';

/**
 * AuditPayload — canonical-payload contract.
 *
 * Field order in this interface is documentation-only — the canonicalizer
 * sorts keys alphabetically at every depth before hashing.
 *
 * OPEN-DECISION-A (M10): M0 audit_log column names retained.
 */
export interface AuditPayload {
  /** INSERT | UPDATE | DELETE. */
  action: AuditAction;
  /**
   * UTC ISO 8601 with microsecond precision: `YYYY-MM-DDTHH:mm:ss.uuuuuuZ`.
   * BE produces this via `makeChangedAtIsoUs()`; PG via
   * `to_char(... AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`.
   */
  changedAt: string;
  /** v_user_id=0 sentinel coerced to NULL (S2-20). */
  changedBy: number | null;
  /** Post-redaction row state for INSERT/UPDATE; NULL for DELETE. */
  newValues: Record<string, unknown> | null;
  /** Post-redaction row state for UPDATE/DELETE; NULL for INSERT. */
  oldValues: Record<string, unknown> | null;
  /** Source-row primary key. NULL for sentinel events (e.g. __demo_purge__). */
  recordId: number | null;
  /** Source table name (e.g. 'contract', '__demo_purge__'). */
  tableName: string;
}

/**
 * AuditChainRecordResult — fn_audit_log_record_v2 JSONB output.
 * Internal-only — NOT exposed at the HTTP layer.
 */
export interface AuditChainRecordResult {
  id: number;
  prevHash: string;
  thisHash: string;
}

/**
 * AuditChainVerifyError — discriminator on a verify-failure response.
 * Strings emitted verbatim by fn_audit_chain_verify.
 */
export type AuditChainVerifyError =
  | 'hash_mismatch'
  | 'prev_hash_chain_break'
  | 'missing_row';

/**
 * AuditChainVerifyResult — fn_audit_chain_verify JSONB output.
 *
 * verified=true   ⇒ brokenAtSeq === null AND error === null.
 * verified=false  ⇒ brokenAtSeq is the offending audit_log.id AND error names
 *                   the failure mode.
 */
export interface AuditChainVerifyResult {
  verified: boolean;
  brokenAtSeq: number | null;
  error: AuditChainVerifyError | null;
  rowsWalked: number;
  /** Wall-clock elapsed milliseconds (NFR target < 30000 @ 100k rows). */
  elapsedMs: number;
}

/** AuditChainVerifyRequest — POST /api/v1/admin/audit/verify body. */
export interface AuditChainVerifyRequest {
  startSeq?: number | null;
  endSeq?: number | null;
}

export type AuditChainVerifyApiResponse = ApiResponse<AuditChainVerifyResult>;
