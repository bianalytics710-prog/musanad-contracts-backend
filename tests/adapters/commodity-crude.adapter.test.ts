/**
 * M7 — Commodity crude adapter tests (CR-A AC-S6-01..02, AC-S6-05).
 *
 *   AC-S6-01 — declares 4 markers + 5-min cadence + reliability 0.90
 *   AC-S6-02 — severity rules: abs(changePct24h) >= 5 → high; >= 2 → medium; else informational
 *   AC-S6-05 — health_check returns state='unauthorised' when env var unset
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import {
  CommodityCrudeAdapter,
  parseCommodityResponse,
} from '../../src/adapters/commodity-crude.adapter';

const fixturePath = (name: string): string =>
  path.resolve(__dirname, '..', 'fixtures', 'osint', 'commodity_crude', name);

describe('CommodityCrudeAdapter — declarations', () => {
  const adapter = new CommodityCrudeAdapter();

  it('AC-S6-01: source_id, refresh_seconds=300, reliability=0.90', () => {
    expect(adapter.source_id).toBe('commodity_crude');
    expect(adapter.refresh_seconds).toBe(300);
    expect(adapter.source_reliability).toBe(0.9);
  });
});

describe('parseCommodityResponse — fixtures', () => {
  it('parses 4 ADNOC markers from a typical response', () => {
    const data = JSON.parse(readFileSync(fixturePath('oilprice_response.json'), 'utf-8'));
    const records = parseCommodityResponse(data);
    expect(records.length).toBe(4);
    expect(records.map((r) => r.marker).sort()).toEqual(['BRENT', 'DUBAI', 'MURBAN', 'WTI']);
  });

  it('returns empty array on empty/malformed payload', () => {
    const data = JSON.parse(readFileSync(fixturePath('empty_response.json'), 'utf-8'));
    expect(parseCommodityResponse(data)).toEqual([]);
    // Truly malformed payload also yields empty array (no throw):
    expect(parseCommodityResponse({ unrelated: 'shape' })).toEqual([]);
  });
});

describe('CommodityCrudeAdapter — severity rules', () => {
  const adapter = new CommodityCrudeAdapter();

  it('AC-S6-02: abs(changePct24h) >= 5 → severity=high', () => {
    const sig = adapter.normalise({
      payload: {
        marker: 'MURBAN',
        price: 79.30,
        changePct24h: -6.8,
        observedAt: '2026-05-09T08:00:00Z',
      },
      fetched_at: new Date('2026-05-09T08:00:00Z'),
    });
    expect(sig.severity).toBe('high');
    expect(sig.kind).toBe('commodity');
    expect(sig.affected_entities[0]!.identifier).toBe('MURBAN');
  });

  it('AC-S6-02: abs(changePct24h) >= 2 (and < 5) → severity=medium', () => {
    const sig = adapter.normalise({
      payload: {
        marker: 'DUBAI', price: 76.15, changePct24h: -2.5, observedAt: '2026-05-09T08:00:00Z',
      },
      fetched_at: new Date('2026-05-09T08:00:00Z'),
    });
    expect(sig.severity).toBe('medium');
  });

  it('AC-S6-02: abs(changePct24h) < 2 → severity=informational', () => {
    const sig = adapter.normalise({
      payload: {
        marker: 'BRENT', price: 78.42, changePct24h: 0.4, observedAt: '2026-05-09T08:00:00Z',
      },
      fetched_at: new Date('2026-05-09T08:00:00Z'),
    });
    expect(sig.severity).toBe('informational');
  });
});

describe('CommodityCrudeAdapter — credential resolution + health_check', () => {
  it('AC-S6-05: missing env var → health_check returns state=unauthorised', async () => {
    const adapter = new CommodityCrudeAdapter({ credential_ref: 'env:CRA_DEFINITELY_UNSET' });
    delete process.env.CRA_DEFINITELY_UNSET;
    const r = await adapter.health_check();
    expect(r.state).toBe('unauthorised');
  });

  it('AC-S6-05: null credential_ref → health_check returns state=unauthorised', async () => {
    const adapter = new CommodityCrudeAdapter({ credential_ref: null });
    const r = await adapter.health_check();
    expect(r.state).toBe('unauthorised');
  });
});
