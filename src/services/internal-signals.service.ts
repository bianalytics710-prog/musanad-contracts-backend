/**
 * M8 — Internal Signal Data Path service (CR-A2).
 *
 * Thin DB-passthrough for the 4 fn_'s in 111_cra2_internal_signal_functions.sql:
 *   - fn_internal_signal_ingest(p_payload JSONB) — DEFINER, system-only.
 *     Caller payload (InternalSignalIngestPayload) is forwarded verbatim;
 *     actor + tenant come from the GUCs set by db.callFunction.
 *   - fn_internal_signal_resolve(p_actor_id BIGINT, p_signal_id BIGINT,
 *     p_resolution_kind TEXT, p_resolution_note TEXT) — INVOKER, idempotent.
 *   - fn_internal_signal_kind_list(p_actor_id BIGINT) — INVOKER STABLE,
 *     bare-array.
 *   - fn_internal_signal_list(p_actor_id BIGINT, p_filter JSONB, p_page,
 *     p_limit) — INVOKER STABLE, paginated.
 *
 * Permission gates live inside each fn_ body (defence-in-depth). Tenant
 * GUC is always set via db.callFunction({ tenantId }) using `req.tenantId`
 * resolved by rls.middleware (Q-DA4 ADNOC fallback for the v1 demo).
 *
 * Service layer is intentionally a no-logic shim (CLAUDE.md §2: "Backend =
 * thin HTTP layer"). The controllers do logging + envelope shaping; the
 * services do exactly one db.callFunction per public fn.
 */
import { db } from '../database/client';
import type {
  InternalSignalIngestPayload,
  InternalSignalIngestResponse,
  InternalSignalKindListResponse,
  InternalSignalListFilter,
  InternalSignalListResponse,
  InternalSignalResolveResponse,
  SignalResolutionKind,
} from '../types/internal-signal.types';

/**
 * POST /api/v1/admin/internal-signals → fn_internal_signal_ingest.
 *
 * The fn takes ONE JSONB arg (the full payload). Actor is read inside the
 * fn body via the `app.current_user_id` GUC set by db.callFunction's actorId
 * option. Idempotent on UNIQUE(tenant_id, dedup_hash) — same payload posted
 * twice yields { inserted: false, dedupHashHit: true } with the same
 * signalId; both return 201.
 */
export const ingestInternalSignal = (
  actorId: number,
  tenantId: string | undefined,
  payload: InternalSignalIngestPayload,
): Promise<InternalSignalIngestResponse> =>
  db.callFunction<InternalSignalIngestResponse>(
    'fn_internal_signal_ingest',
    [payload],
    { actorId, tenantId },
  );

/**
 * GET /api/v1/admin/internal-signal-kinds → fn_internal_signal_kind_list.
 *
 * Bare-array shape (no pagination envelope) — bounded set (8 rows per
 * tenant) per AC-S6-01 and the M7 fn_source_health_list precedent.
 */
export const listInternalSignalKinds = (
  actorId: number,
  tenantId: string | undefined,
): Promise<InternalSignalKindListResponse> =>
  db.callFunction<InternalSignalKindListResponse>(
    'fn_internal_signal_kind_list',
    [actorId],
    { actorId, tenantId },
  );

/**
 * GET /api/v1/internal-signals → fn_internal_signal_list.
 *
 * Filter map (per db-design.md §5.4.1): signalType / contractId / vendorId /
 * since / status. The fn validates each filter value internally and raises
 * 22023 for invalid signalType / status values (Zod is the first line of
 * defence; fn raises are defence-in-depth + the source of truth).
 *
 * Pagination clamping mirrors M7 fn_osint_signal_list (LEAST(p_limit, 100)).
 */
export const listInternalSignals = (
  actorId: number,
  tenantId: string | undefined,
  filter: InternalSignalListFilter,
  page: number,
  limit: number,
): Promise<InternalSignalListResponse> => {
  // Build the JSONB filter object — only include keys the caller supplied so
  // the fn body's `(filter ? 'key')` checks behave as documented.
  const filterPayload: Record<string, unknown> = {};
  if (filter.signalType !== undefined) filterPayload['signalType'] = filter.signalType;
  if (filter.contractId !== undefined) filterPayload['contractId'] = filter.contractId;
  if (filter.vendorId !== undefined) filterPayload['vendorId'] = filter.vendorId;
  if (filter.since !== undefined) filterPayload['since'] = filter.since;
  // status='all' is the no-predicate sentinel — strip it before passing to
  // the fn so the fn's `v_status NOT IN ('open','resolved')` raise doesn't
  // trip. Per types.ts, 'all' is a controller-side default.
  if (filter.status !== undefined && filter.status !== 'all') {
    filterPayload['status'] = filter.status;
  }

  return db.callFunction<InternalSignalListResponse>(
    'fn_internal_signal_list',
    [actorId, filterPayload, page, limit],
    { actorId, tenantId },
  );
};

/**
 * POST /api/v1/internal-signals/:id/resolve → fn_internal_signal_resolve.
 *
 * Idempotent — re-resolve of an already-resolved signal returns the existing
 * { signalId, resolvedAt, resolvedBy } values unchanged AND skips the
 * pg_notify (AC-S5-03). The fn body sets `idempotent: true` on the response
 * envelope in that case.
 *
 * Role-mapping permission gate lives inside the fn body (Q-DA3 hardcoded
 * CASE on signal_kind_subtype). 42501 from the role gate maps to
 * ForbiddenError via translatePgError.
 */
export const resolveInternalSignal = (
  actorId: number,
  tenantId: string | undefined,
  signalId: number,
  resolutionKind: SignalResolutionKind,
  resolutionNote: string | null,
): Promise<InternalSignalResolveResponse> =>
  db.callFunction<InternalSignalResolveResponse>(
    'fn_internal_signal_resolve',
    [actorId, signalId, resolutionKind, resolutionNote],
    { actorId, tenantId },
  );
