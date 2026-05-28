/**
 * M7 — SourceAdapter protocol contract (CR-A).
 *
 * Re-exports the SourceAdapter / RawSignal / NormalisedSignal interfaces and
 * the helper types from `src/types/osint.types.ts`. Per AC-S4-01 the contract
 * uses snake_case keys verbatim from the brief Backend section so cross-
 * language reference implementations stay signature-compatible.
 *
 * Adapters implement this interface and the fetch worker dispatches to them
 * keyed by `source_id`. Each adapter ALSO exposes a `normalise(raw)` method
 * that converts upstream payload to the Annex B.2.1 NormalisedSignal shape;
 * the worker then calls fn_osint_signal_upsert with a camelCase remap.
 */
import { createHash } from 'node:crypto';

export type {
  SourceAdapter,
  RawSignal,
  NormalisedSignal,
  AdapterHealthCheckResult,
  RateLimitConfig,
  GeoReference,
  EntityReference,
  SignalKind,
  Severity,
  HealthState,
  SeverityMapping,
  SeverityMappingRule,
  GeographyFilter,
} from '../types/osint.types';

/**
 * SHA-256 dedup hash — stable, content-based identity for a signal:
 *   sha256(source_id || '|' || isoformat(event_date) || '|' || lower(trim(title)))
 *
 * IMPORTANT: the dedup key must NOT depend on fetch time. A previous version
 * fell back to `fetched_at` when `event_date` was absent, which made the hash
 * change on every poll — so list-style sources with no per-entry date
 * (sanctions lists especially) re-inserted their entire payload on every pull
 * (the OFAC SDN list alone produced ~469k duplicate rows). Records that
 * genuinely change over time carry an `event_date`; records without one
 * (e.g. a sanctions-list entry) dedup on (source_id, title) identity, which is
 * correct — the same entity should collapse to one row.
 *
 * `fetchedAt` is retained in the signature for call-site compatibility but is
 * intentionally not part of the hash.
 *
 * Used by every adapter normalise() to populate NormalisedSignal.dedup_hash;
 * fn_osint_signal_upsert ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
 * leverages this to make ingestion idempotent across re-pulls (AC-S7-03).
 */
export const computeDedupHash = (
  sourceId: string,
  eventDate: Date | undefined,
  _fetchedAt: Date,
  title: string,
): string => {
  const ts = eventDate ? eventDate.toISOString() : '';
  const norm = `${sourceId}|${ts}|${title.trim().toLowerCase()}`;
  return createHash('sha256').update(norm, 'utf8').digest('hex');
};

/**
 * Resolve the runtime credential value for an adapter from osint_source's
 * source_credential.credential_ref. CR-A uses KMS-style env-var indirection
 * (Q3 + Q-NEW6 lock):
 *
 *   credential_ref = 'env:VARNAME' → process.env['VARNAME']
 *   credential_ref = 'vault:path'  → not yet implemented (CR-C)
 *   credential_ref = null          → returns undefined
 *
 * Returns undefined when the env var is unset; adapters detect this and
 * return health_check() state='unauthorised' per AC-S6-05.
 */
export const resolveCredential = (credentialRef: string | null | undefined): string | undefined => {
  if (!credentialRef || typeof credentialRef !== 'string') return undefined;
  if (credentialRef.startsWith('env:')) {
    const varName = credentialRef.slice(4);
    if (varName.length === 0) return undefined;
    return process.env[varName];
  }
  // vault: scheme reserved for CR-C; treat as unresolved in CR-A.
  return undefined;
};
