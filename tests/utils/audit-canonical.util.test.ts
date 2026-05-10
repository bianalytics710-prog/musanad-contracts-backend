/**
 * CR-C — audit-canonical.util.ts unit tests + cross-platform parity fixtures.
 *
 * The 3 fixtures originate from db-design.md §2.1a and the workspace
 * seed-data.ts auditCanonicalParityFixtures. Each fixture passes the SAME
 * input to BOTH:
 *   - the BE canonicalize() function (this file)
 *   - the PG fn_audit_log_canonicalize(JSONB)
 *
 * BE-only assertions live here. The PG-side parity check is performed by
 * tests/db/CR-C-audit-canonical-parity.test.ts (out of scope for this file —
 * Testing Agent owns it). Both layers MUST agree byte-for-byte; the golden
 * `expected` values below are the source of truth.
 */
import { describe, it, expect } from 'vitest';
import {
  GENESIS_PREV_HASH,
  canonicalize,
  hashPayload,
  makeChangedAtIsoUs,
} from '../../src/utils/audit-canonical.util';
import type { AuditPayload } from '../../src/utils/audit-canonical.util';

interface ParityFixture {
  description: string;
  input: Record<string, unknown>;
  expected: string;
  /** Optional pre-computed SHA-256 hex over GENESIS_PREV_HASH || canonical. */
  expectedHashGenesis?: string;
}

const PARITY_FIXTURES: ReadonlyArray<ParityFixture> = [
  {
    description:
      'AuditPayload-shaped row — keys sorted alphabetically at every depth',
    input: {
      action: 'INSERT',
      tableName: 'contract',
      recordId: 42,
      oldValues: null,
      newValues: { id: 42, title: 'EPC SLA', amount: 100000 },
      changedBy: 7,
      changedAt: '2026-05-10T06:30:00.123456Z',
    },
    expected:
      '{"action":"INSERT","changedAt":"2026-05-10T06:30:00.123456Z","changedBy":7,"newValues":{"amount":100000,"id":42,"title":"EPC SLA"},"oldValues":null,"recordId":42,"tableName":"contract"}',
  },
  {
    description:
      'Array order preserved AND object keys sorted (independent invariants)',
    input: { a: [3, 1, 2], b: { z: 1, a: 2 } },
    expected: '{"a":[3,1,2],"b":{"a":2,"z":1}}',
  },
  {
    description: 'NULLs explicit; false preserved; empty string preserved',
    input: { x: null, y: false, z: '' },
    expected: '{"x":null,"y":false,"z":""}',
  },
];

describe('audit-canonical.util — parity fixtures (AC-S1-05)', () => {
  for (const fx of PARITY_FIXTURES) {
    it(fx.description, () => {
      const got = canonicalize(fx.input);
      expect(got).toBe(fx.expected);
    });
  }
});

describe('audit-canonical.util — primitives', () => {
  it('null / undefined → "null"', () => {
    expect(canonicalize(null)).toBe('null');
    expect(canonicalize(undefined)).toBe('null');
  });

  it('booleans', () => {
    expect(canonicalize(true)).toBe('true');
    expect(canonicalize(false)).toBe('false');
  });

  it('numbers preserve canonical form (no trailing zeros)', () => {
    expect(canonicalize(0)).toBe('0');
    expect(canonicalize(42)).toBe('42');
    expect(canonicalize(-1.5)).toBe('-1.5');
    expect(canonicalize(1e10)).toBe('10000000000');
  });

  it('NaN / Infinity → "null" (matches PG coerce-to-null semantics)', () => {
    expect(canonicalize(NaN)).toBe('null');
    expect(canonicalize(Infinity)).toBe('null');
    expect(canonicalize(-Infinity)).toBe('null');
  });

  it('strings JSON-escaped', () => {
    expect(canonicalize('hello')).toBe('"hello"');
    expect(canonicalize('a"b')).toBe('"a\\"b"');
    expect(canonicalize('line\nbreak')).toBe('"line\\nbreak"');
  });

  it('empty array / empty object', () => {
    expect(canonicalize([])).toBe('[]');
    expect(canonicalize({})).toBe('{}');
  });

  it('arrays preserve order; nested objects sort keys', () => {
    expect(canonicalize([{ b: 1, a: 2 }, { z: 9 }])).toBe(
      '[{"a":2,"b":1},{"z":9}]',
    );
  });
});

describe('audit-canonical.util — hashPayload', () => {
  it('GENESIS_PREV_HASH is 64 zero chars', () => {
    expect(GENESIS_PREV_HASH).toBe('0'.repeat(64));
    expect(GENESIS_PREV_HASH.length).toBe(64);
  });

  it('hashPayload returns 64-char hex', () => {
    const payload: AuditPayload = {
      action: 'INSERT',
      changedAt: '2026-05-10T06:30:00.123456Z',
      changedBy: 7,
      newValues: { id: 42 },
      oldValues: null,
      recordId: 42,
      tableName: 'contract',
    };
    const h = hashPayload(GENESIS_PREV_HASH, payload);
    expect(h).toMatch(/^[0-9a-f]{64}$/);
  });

  it('different inputs → different hashes', () => {
    const a: AuditPayload = {
      action: 'INSERT',
      changedAt: '2026-05-10T06:30:00.123456Z',
      changedBy: 7,
      newValues: { id: 1 },
      oldValues: null,
      recordId: 1,
      tableName: 'x',
    };
    const b: AuditPayload = { ...a, recordId: 2, newValues: { id: 2 } };
    expect(hashPayload(GENESIS_PREV_HASH, a)).not.toBe(
      hashPayload(GENESIS_PREV_HASH, b),
    );
  });

  it('same input → same hash (deterministic)', () => {
    const p: AuditPayload = {
      action: 'UPDATE',
      changedAt: '2026-05-10T06:30:00.000000Z',
      changedBy: null,
      newValues: { a: 1 },
      oldValues: { a: 0 },
      recordId: 99,
      tableName: 'y',
    };
    expect(hashPayload(GENESIS_PREV_HASH, p)).toBe(
      hashPayload(GENESIS_PREV_HASH, p),
    );
  });
});

describe('audit-canonical.util — makeChangedAtIsoUs', () => {
  it('matches the YYYY-MM-DDTHH:mm:ss.uuuuuuZ shape', () => {
    const ts = makeChangedAtIsoUs();
    expect(ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/);
  });

  it('is millisecond-aligned with the supplied Date', () => {
    const fixed = new Date('2026-05-10T06:30:00.123Z');
    const ts = makeChangedAtIsoUs(fixed);
    expect(ts.startsWith('2026-05-10T06:30:00.123')).toBe(true);
    expect(ts.endsWith('Z')).toBe(true);
  });
});
