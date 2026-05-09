/**
 * M7 — EU Consolidated Sanctions adapter tests (CR-A AC-S4-01..05).
 *
 * Covers contract conformance + normalise() output. The base XmlSanctionsBaseAdapter
 * shared by EU/UN/UK is exercised via three formal fixtures.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { EuConsolidatedAdapter } from '../../src/adapters/eu-consolidated.adapter';
import type { XmlSanctionsEntry } from '../../src/adapters/xml-sanctions-base.adapter';

const fixturePath = (name: string): string =>
  path.resolve(__dirname, '..', 'fixtures', 'osint', 'eu_consolidated', name);

describe('EuConsolidatedAdapter', () => {
  const adapter = new EuConsolidatedAdapter();

  it('AC-S4-02: declares source_reliability=1.0 and refresh_seconds=86400', () => {
    expect(adapter.source_id).toBe('eu_consolidated');
    expect(adapter.source_reliability).toBe(1.0);
    expect(adapter.refresh_seconds).toBe(86400);
  });

  it('parse() handles minimal-fallback XML gracefully (does not throw on shape mismatch)', () => {
    const xml = readFileSync(fixturePath('minimal.xml'), 'utf-8');
    const entries = adapter.parse(xml);
    // Either resolves the placeholder structure into 0 entries (if firstMatchingArray
    // doesn't find a known shape) OR produces some entries. Either way, must not throw.
    expect(Array.isArray(entries)).toBe(true);
  });

  it('normalise() produces a NormalisedSignal with severity=high (no CAATSA carve-out)', () => {
    const synth: XmlSanctionsEntry = {
      uid: 'EU-30001',
      name: 'Demo EU Sanctions Test Entity',
      programs: ['RUSSIA'],
      remarks: 'Council Decision (CFSP) 2014/512',
    };
    const sig = adapter.normalise({ payload: synth as unknown as Record<string, unknown>, fetched_at: new Date('2026-05-09T00:00:00Z') });
    expect(sig.kind).toBe('sanctions');
    expect(sig.severity).toBe('high');
    expect(sig.source_id).toBe('eu_consolidated');
    expect(sig.affected_entities[0]!.identifier).toBe('EU-30001');
    expect(sig.title.startsWith('EU sanctions:')).toBe(true);
  });
});
