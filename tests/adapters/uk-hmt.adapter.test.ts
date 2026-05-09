/**
 * M7 — UK HMT Consolidated Sanctions adapter tests (CR-A AC-S4-01..05).
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { UkHmtAdapter } from '../../src/adapters/uk-hmt.adapter';
import type { XmlSanctionsEntry } from '../../src/adapters/xml-sanctions-base.adapter';

const fixturePath = (name: string): string =>
  path.resolve(__dirname, '..', 'fixtures', 'osint', 'uk_hmt', name);

describe('UkHmtAdapter', () => {
  const adapter = new UkHmtAdapter();

  it('AC-S4-02: declares source_reliability=1.0 and refresh_seconds=86400', () => {
    expect(adapter.source_id).toBe('uk_hmt');
    expect(adapter.source_reliability).toBe(1.0);
    expect(adapter.refresh_seconds).toBe(86400);
  });

  it('parse() handles minimal-fallback fixture without throwing', () => {
    const xml = readFileSync(fixturePath('minimal.xml'), 'utf-8');
    const entries = adapter.parse(xml);
    expect(Array.isArray(entries)).toBe(true);
  });

  it('normalise() produces sanctions/high signal with UK HMT title prefix', () => {
    const synth: XmlSanctionsEntry = {
      uid: 'UK-5001',
      name: 'HMT Test Designated Individual',
      programs: ['RUS'],
    };
    const sig = adapter.normalise({ payload: synth as unknown as Record<string, unknown>, fetched_at: new Date('2026-05-09T00:00:00Z') });
    expect(sig.kind).toBe('sanctions');
    expect(sig.severity).toBe('high');
    expect(sig.source_id).toBe('uk_hmt');
    expect(sig.title).toContain('UK HMT sanctions:');
  });
});
