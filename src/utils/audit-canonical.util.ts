/**
 * CR-C — audit canonical serializer (Annex D.7.1 single source of truth).
 *
 * This module is the BE-side mirror of PG `fn_audit_log_canonicalize(JSONB)`.
 * The two implementations MUST emit byte-identical canonical-JSON for any
 * given AuditPayload — verified by tests/utils/audit-canonical.util.test.ts
 * (AC-S1-05).
 *
 * Algorithm:
 *   - Object keys sorted alphabetically at every depth.
 *   - Array element ORDER preserved (arrays are ordered values).
 *   - Strings JSON-escaped via JSON.stringify (covers control chars + quotes).
 *   - Numbers serialised via String() (canonical numeric form — no trailing zeros).
 *   - Booleans → 'true' | 'false'.
 *   - null / undefined / missing → 'null' (NULLs explicit).
 *
 * Timestamp helper:
 *   `makeChangedAtIsoUs()` returns a UTC ISO 8601 with microsecond precision
 *   ('YYYY-MM-DDTHH:mm:ss.uuuuuuZ'). PG mirrors this via:
 *     to_char(<ts> AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
 *
 *   Note: M0 audit_log column names are honored at canonicalize-input level
 *   (action / changedAt / changedBy / newValues / oldValues / recordId /
 *   tableName). Annex D.7.1 column-name retrofit (tenantId / userId /
 *   entityType / entityId / beforeState / afterState / metadata / timestamp)
 *   is deferred to post-pilot per OPEN-DECISION-A.
 *
 * Hash helper:
 *   `hashPayload(prevHash, payload)` → SHA-256 hex of (prevHash || canonical).
 *   Mirrors `encode(digest(prev_hash || canonical, 'sha256'), 'hex')` in PG.
 */
import { createHash } from 'node:crypto';

import type { AuditPayload } from '../types/admin-audit-chain.types';

export type { AuditPayload };

/**
 * Recursively canonicalise a JSONB-shaped value to its deterministic string form.
 *
 * Pure / referentially transparent — same input → same output. Idempotent.
 *
 * @example
 *   canonicalize({ b: 2, a: 1 }) // '{"a":1,"b":2}'
 *   canonicalize([3, 1, 2])      // '[3,1,2]'  (order preserved)
 *   canonicalize(null)           // 'null'
 */
export function canonicalize(payload: unknown): string {
  if (payload === null || payload === undefined) return 'null';
  if (typeof payload === 'boolean') return payload ? 'true' : 'false';
  if (typeof payload === 'number') {
    // PG numeric canonical form. NaN / Infinity are not valid JSONB —
    // emit 'null' to match PG's coerce-to-null behaviour rather than 'NaN'.
    if (!Number.isFinite(payload)) return 'null';
    return String(payload);
  }
  if (typeof payload === 'string') return JSON.stringify(payload);
  if (Array.isArray(payload)) {
    return '[' + payload.map(canonicalize).join(',') + ']';
  }
  if (typeof payload === 'object') {
    const obj = payload as Record<string, unknown>;
    const keys = Object.keys(obj).sort();
    return (
      '{' +
      keys.map((k) => JSON.stringify(k) + ':' + canonicalize(obj[k])).join(',') +
      '}'
    );
  }
  // Fallback — symbols / functions / bigint not part of JSONB.
  return 'null';
}

/**
 * UTC ISO 8601 timestamp with microsecond precision.
 *
 * Date.toISOString() only carries millisecond precision. We append three
 * additional digits derived from process.hrtime.bigint() so the byte-string
 * shape exactly matches the PG to_char(... 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
 * rendering (six fractional digits).
 *
 * The extra digits are NOT clock-aligned with millisecond — they are derived
 * from the high-resolution monotonic clock — but they preserve the format
 * expected by canonicalize() / hashPayload().
 */
export function makeChangedAtIsoUs(now: Date = new Date()): string {
  const ms = now.toISOString();
  // 'YYYY-MM-DDTHH:mm:ss.SSSZ' → 24 chars; replace 'SSSZ' with 'SSSuuuZ'.
  const usDigits = String(process.hrtime.bigint() % 1000n).padStart(3, '0');
  return ms.slice(0, -1) + usDigits + 'Z';
}

/**
 * Compute SHA-256 hex of (prevHash || canonical_payload). Mirrors the PG
 * hash construction in fn_audit_log_record_v2:
 *
 *   v_canonical := fn_audit_log_canonicalize(jsonb_build_object(...));
 *   v_this_hash := encode(digest(v_prev_hash || v_canonical, 'sha256'), 'hex');
 *
 * Use `repeat('0', 64)` (64-char zero string) as the genesis-row prev_hash.
 */
export function hashPayload(prevHash: string, payload: AuditPayload): string {
  const canonical = canonicalize(payload as unknown as Record<string, unknown>);
  return createHash('sha256').update(prevHash + canonical).digest('hex');
}

/** 64-char zero string used as the genesis-row prev_hash. */
export const GENESIS_PREV_HASH = '0'.repeat(64);
