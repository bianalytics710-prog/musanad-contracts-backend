/**
 * M7 — UN Security Council adapter tests (CR-A AC-S4-01..05).
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { UnSecurityCouncilAdapter } from '../../src/adapters/un-security-council.adapter';
import type { XmlSanctionsEntry } from '../../src/adapters/xml-sanctions-base.adapter';

const fixturePath = (name: string): string =>
  path.resolve(__dirname, '..', 'fixtures', 'osint', 'un_security_council', name);

describe('UnSecurityCouncilAdapter', () => {
  const adapter = new UnSecurityCouncilAdapter();

  it('AC-S4-02: declares source_reliability=1.0 and refresh_seconds=86400', () => {
    expect(adapter.source_id).toBe('un_security_council');
    expect(adapter.source_reliability).toBe(1.0);
    expect(adapter.refresh_seconds).toBe(86400);
  });

  it('parse() does not throw on minimal-fallback fixture', () => {
    const xml = readFileSync(fixturePath('minimal.xml'), 'utf-8');
    const entries = adapter.parse(xml);
    expect(Array.isArray(entries)).toBe(true);
  });

  it('normalise() produces sanctions/high signal with UN sanctions title prefix', () => {
    const synth: XmlSanctionsEntry = {
      uid: 'UN-1234',
      name: 'UN-Listed Entity',
      programs: ['1267/1989'],
      remarks: 'UNSC consolidated list',
    };
    const sig = adapter.normalise({ payload: synth as unknown as Record<string, unknown>, fetched_at: new Date('2026-05-09T00:00:00Z') });
    expect(sig.kind).toBe('sanctions');
    expect(sig.severity).toBe('high');
    expect(sig.source_id).toBe('un_security_council');
    expect(sig.title).toMatch(/UN sanctions:|UN_SECURITY_COUNCIL:/);
  });
});
