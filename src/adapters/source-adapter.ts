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
 * SHA-256 dedup hash per Annex B + design note:
 *   sha256(source_id || '|' || isoformat(event_date OR fetched_at) || '|'
 *          || lower(trim(title)))
 *
 * Used by every adapter normalise() to populate NormalisedSignal.dedup_hash;
 * fn_osint_signal_upsert ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
 * leverages this to make ingestion idempotent (AC-S7-03).
 */
export const computeDedupHash = (
  sourceId: string,
  eventDate: Date | undefined,
  fetchedAt: Date,
  title: string,
): string => {
  const ts = (eventDate ?? fetchedAt).toISOString();
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
