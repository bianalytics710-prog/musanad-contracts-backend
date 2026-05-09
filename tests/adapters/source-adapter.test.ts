/**
 * M7 — SourceAdapter protocol contract + helpers (CR-A AC-S4-01).
 *
 * Verifies computeDedupHash() canonical algorithm + resolveCredential()
 * KMS-style env-var indirection.
 */
import { describe, it, expect } from 'vitest';
import { createHash } from 'node:crypto';
import {
  computeDedupHash,
  resolveCredential,
} from '../../src/adapters/source-adapter';

const sha256 = (s: string): string =>
  createHash('sha256').update(s, 'utf8').digest('hex');

describe('computeDedupHash — canonical SHA-256(source_id|date|title.trim().lower)', () => {
  it('uses event_date when present', () => {
    const eventDate = new Date('2026-05-08T12:00:00Z');
    const fetchedAt = new Date('2026-05-09T00:00:00Z');
    const h = computeDedupHash('ofac_sdn', eventDate, fetchedAt, '  Some Title  ');
    expect(h).toBe(sha256('ofac_sdn|2026-05-08T12:00:00.000Z|some title'));
  });

  it('falls back to fetched_at when event_date is undefined', () => {
    const fetchedAt = new Date('2026-05-09T00:00:00Z');
    const h = computeDedupHash('ofac_sdn', undefined, fetchedAt, 'Title');
    expect(h).toBe(sha256('ofac_sdn|2026-05-09T00:00:00.000Z|title'));
  });

  it('always returns 64-char hex', () => {
    const h = computeDedupHash('any', undefined, new Date(), 'x');
    expect(h.length).toBe(64);
    expect(/^[a-f0-9]+$/.test(h)).toBe(true);
  });
});

describe('resolveCredential — env-var indirection', () => {
  it('resolves env:VARNAME to process.env value', () => {
    process.env.CRA_TEST_RESOLVE = 'secret-value-not-logged';
    expect(resolveCredential('env:CRA_TEST_RESOLVE')).toBe('secret-value-not-logged');
    delete process.env.CRA_TEST_RESOLVE;
  });

  it('returns undefined for missing env var', () => {
    delete process.env.CRA_TEST_MISSING;
    expect(resolveCredential('env:CRA_TEST_MISSING')).toBeUndefined();
  });

  it('returns undefined for null / empty / unsupported scheme', () => {
    expect(resolveCredential(null)).toBeUndefined();
    expect(resolveCredential(undefined)).toBeUndefined();
    expect(resolveCredential('')).toBeUndefined();
    expect(resolveCredential('vault:still-not-implemented')).toBeUndefined();
  });
});
