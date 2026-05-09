/**
 * M7 — OFAC SDN adapter unit tests (CR-A AC-S4-01..05).
 *
 * Verifies parseOfacXml() against fixtures and OfacSdnAdapter.normalise()
 * applies the CAATSA/NSPM-25 → critical severity rule, dedup_hash is the
 * canonical SHA-256(source_id|event_date_or_fetched_at|title) value, and
 * normalise() output conforms to the NormalisedSignal shape.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import {
  OfacSdnAdapter,
  parseOfacXml,
} from '../../src/adapters/ofac-sdn.adapter';

const fixturePath = (name: string): string =>
  path.resolve(__dirname, '..', 'fixtures', 'osint', 'ofac_sdn', name);

const sha256 = (s: string): string =>
  createHash('sha256').update(s, 'utf8').digest('hex');

describe('OfacSdnAdapter — parseOfacXml fixtures', () => {
  it('AC-S4-02: parses minimal SDN XML into one entry', () => {
    const xml = readFileSync(fixturePath('minimal.xml'), 'utf-8');
    const entries = parseOfacXml(xml);
    expect(entries.length).toBe(1);
    expect(entries[0]!.uid).toBe('10001');
    expect(entries[0]!.firstName).toBe('Acme');
    expect(entries[0]!.lastName).toBe('Holdings Limited');
    expect(entries[0]!.programs).toEqual(['SDGT']);
  });

  it('AC-S4-02: parses CAATSA/NSPM-25 fixture into two entries with multiple programs', () => {
    const xml = readFileSync(fixturePath('caatsa.xml'), 'utf-8');
    const entries = parseOfacXml(xml);
    expect(entries.length).toBe(2);
    const caatsa = entries.find((e) => e.uid === '20002')!;
    expect(caatsa.programs).toContain('CAATSA - RUSSIA');
    const nspm = entries.find((e) => e.uid === '20003')!;
    expect(nspm.programs).toContain('NSPM-25');
  });

  it('handles empty SDN list gracefully', () => {
    const xml = readFileSync(fixturePath('empty.xml'), 'utf-8');
    const entries = parseOfacXml(xml);
    expect(entries).toEqual([]);
  });
});

describe('OfacSdnAdapter — normalise + severity', () => {
  const adapter = new OfacSdnAdapter();

  it('AC-S4-02: declares source_reliability=1.0 and refresh_seconds=86400', () => {
    expect(adapter.source_id).toBe('ofac_sdn');
    expect(adapter.source_reliability).toBe(1.0);
    expect(adapter.refresh_seconds).toBe(86400);
  });

  it('AC-S4-03: program containing CAATSA → severity=critical', () => {
    const xml = readFileSync(fixturePath('caatsa.xml'), 'utf-8');
    const entries = parseOfacXml(xml);
    const caatsa = entries.find((e) => e.uid === '20002')!;
    const fetchedAt = new Date('2026-05-09T00:00:00Z');
    const sig = adapter.normalise({ payload: caatsa as unknown as Record<string, unknown>, fetched_at: fetchedAt });
    expect(sig.severity).toBe('critical');
    expect(sig.kind).toBe('sanctions');
    expect(sig.source_id).toBe('ofac_sdn');
    expect(sig.source_reliability).toBe(1.0);
    expect(sig.affected_entities.length).toBe(1);
    expect(sig.affected_entities[0]!.identifier).toBe('20002');
  });

  it('AC-S4-03: NSPM-25 program → severity=critical', () => {
    const xml = readFileSync(fixturePath('caatsa.xml'), 'utf-8');
    const entries = parseOfacXml(xml);
    const nspm = entries.find((e) => e.uid === '20003')!;
    const sig = adapter.normalise({ payload: nspm as unknown as Record<string, unknown>, fetched_at: new Date() });
    expect(sig.severity).toBe('critical');
  });

  it('AC-S4-03: non-CAATSA/non-NSPM program (SDGT) → severity=high', () => {
    const xml = readFileSync(fixturePath('minimal.xml'), 'utf-8');
    const entry = parseOfacXml(xml)[0]!;
    const sig = adapter.normalise({ payload: entry as unknown as Record<string, unknown>, fetched_at: new Date() });
    expect(sig.severity).toBe('high');
  });

  it('AC-S4-04: dedup_hash is canonical SHA-256(source_id|fetched_at_iso|title.lower)', () => {
    const xml = readFileSync(fixturePath('minimal.xml'), 'utf-8');
    const entry = parseOfacXml(xml)[0]!;
    const fetchedAt = new Date('2026-05-09T00:00:00Z');
    const sig = adapter.normalise({ payload: entry as unknown as Record<string, unknown>, fetched_at: fetchedAt });
    const expected = sha256(
      `ofac_sdn|${fetchedAt.toISOString()}|${sig.title.trim().toLowerCase()}`,
    );
    expect(sig.dedup_hash).toBe(expected);
    expect(sig.dedup_hash.length).toBe(64); // hex
  });
});
