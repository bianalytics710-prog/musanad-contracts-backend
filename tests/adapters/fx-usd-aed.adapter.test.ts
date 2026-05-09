/**
 * M7 — USD/AED FX adapter tests (CR-A AC-S6-03..04).
 *
 *   AC-S6-03 — pairs USD/AED + USD/EUR + USD/GBP + USD/INR; refresh=300; reliability=0.85
 *   AC-S6-04 — peg deviation > 0.5% → high; > 0.25% → medium; else informational
 *   provider failover — primary parser → fallback parser shape both work
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import {
  FxAdapter,
  parseExchangerateHost,
  parseOpenErApi,
} from '../../src/adapters/fx-usd-aed.adapter';

const fixturePath = (name: string): string =>
  path.resolve(__dirname, '..', 'fixtures', 'osint', 'fx_usd_aed', name);

describe('FxAdapter — declarations', () => {
  const adapter = new FxAdapter();
  it('AC-S6-03: source_id=fx_usd_aed, refresh_seconds=300, reliability=0.85', () => {
    expect(adapter.source_id).toBe('fx_usd_aed');
    expect(adapter.refresh_seconds).toBe(300);
    expect(adapter.source_reliability).toBe(0.85);
  });
});

describe('parseExchangerateHost / parseOpenErApi — fixtures', () => {
  it('AC-S6-03: parseExchangerateHost extracts the 4 pairs (AED, EUR, GBP, INR)', () => {
    const data = JSON.parse(readFileSync(fixturePath('exchangerate_host.json'), 'utf-8'));
    const records = parseExchangerateHost(data);
    expect(records.length).toBe(4);
    const pairs = records.map((r) => r.pair).sort();
    expect(pairs).toEqual(['AED', 'EUR', 'GBP', 'INR']);
    expect(records[0]!.provider).toBe('exchangerate.host');
  });

  it('AC-S6-03: parseOpenErApi handles fallback shape', () => {
    const data = JSON.parse(readFileSync(fixturePath('openerapi_fallback.json'), 'utf-8'));
    const records = parseOpenErApi(data);
    expect(records.length).toBe(4);
    const aed = records.find((r) => r.pair === 'AED')!;
    expect(aed.provider).toBe('open.er-api.com');
  });

  it('returns empty array on empty payload', () => {
    expect(parseExchangerateHost({})).toEqual([]);
    expect(parseOpenErApi({})).toEqual([]);
  });
});

describe('FxAdapter — peg deviation severity (AC-S6-04)', () => {
  const adapter = new FxAdapter();

  it('peg-on (3.6725) → severity=informational', () => {
    const sig = adapter.normalise({
      payload: {
        pair: 'AED', rate: 3.6725, base: 'USD',
        observedAt: '2026-05-09T00:00:00Z', provider: 'exchangerate.host',
      },
      fetched_at: new Date('2026-05-09T00:00:00Z'),
    });
    expect(sig.severity).toBe('informational');
    expect(sig.kind).toBe('fx');
  });

  it('peg drift > 0.5% (rate=3.71 → ~1.02% deviation) → severity=high', () => {
    const sig = adapter.normalise({
      payload: {
        pair: 'AED', rate: 3.71, base: 'USD',
        observedAt: '2026-05-09T00:00:00Z', provider: 'exchangerate.host',
      },
      fetched_at: new Date('2026-05-09T00:00:00Z'),
    });
    expect(sig.severity).toBe('high');
  });

  it('peg drift between 0.25% and 0.5% (rate=3.69 → ~0.48% deviation) → severity=medium', () => {
    const sig = adapter.normalise({
      payload: {
        pair: 'AED', rate: 3.69, base: 'USD',
        observedAt: '2026-05-09T00:00:00Z', provider: 'exchangerate.host',
      },
      fetched_at: new Date('2026-05-09T00:00:00Z'),
    });
    expect(sig.severity).toBe('medium');
  });

  it('non-AED pairs are always informational', () => {
    const sig = adapter.normalise({
      payload: {
        pair: 'EUR', rate: 0.85, base: 'USD',
        observedAt: '2026-05-09T00:00:00Z', provider: 'exchangerate.host',
      },
      fetched_at: new Date('2026-05-09T00:00:00Z'),
    });
    expect(sig.severity).toBe('informational');
  });

  it('dedup_hash is canonical and 64-char hex', () => {
    const sig = adapter.normalise({
      payload: {
        pair: 'AED', rate: 3.6725, base: 'USD',
        observedAt: '2026-05-09T00:00:00Z', provider: 'exchangerate.host',
      },
      fetched_at: new Date('2026-05-09T00:00:00Z'),
    });
    expect(sig.dedup_hash.length).toBe(64);
    expect(/^[a-f0-9]+$/.test(sig.dedup_hash)).toBe(true);
  });
});
