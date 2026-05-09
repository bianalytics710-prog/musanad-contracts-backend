/**
 * M7 — RSS aggregator adapter tests (CR-A AC-S5-01..03).
 *
 * Verifies:
 *   - normalise() emits kind=news, severity defaults to 'informational' (AC-S5-03)
 *   - severity_mapping rules escalate matching titles per AC-S5-03
 *   - fanOutRssAdapters fault-isolates one feed throwing (AC-S5-02 / AC-S5-04)
 */
import { describe, it, expect } from 'vitest';
import {
  RssAdapter,
  fanOutRssAdapters,
} from '../../src/adapters/rss-aggregator.adapter';
import type { RawSignal } from '../../src/adapters/source-adapter';

const buildRaw = (title: string, contentSnippet = '', isoDate = ''): RawSignal => ({
  payload: {
    title,
    link: 'https://example.com/x',
    isoDate,
    pubDate: '',
    contentSnippet,
    guid: title,
  },
  fetched_at: new Date('2026-05-09T00:00:00Z'),
});

describe('RssAdapter — single-feed normalise()', () => {
  const adapter = new RssAdapter({
    source_id: 'rss_reuters_energy',
    url: 'https://www.reuters.com/business/energy/rss',
    source_reliability: 0.95,
    severity_rules: [
      { titleContains: 'sanctions', severity: 'high' },
      { titleContains: 'force majeure', severity: 'medium' },
      { default: 'informational' },
    ],
  });

  it('declares refresh_seconds=900', () => {
    expect(adapter.refresh_seconds).toBe(900);
  });

  it('AC-S5-03: default severity is informational for headline with no rule match', () => {
    const sig = adapter.normalise(buildRaw('Generic energy market update'));
    expect(sig.severity).toBe('informational');
    expect(sig.kind).toBe('news');
    expect(sig.source_id).toBe('rss_reuters_energy');
    expect(sig.source_reliability).toBe(0.95);
  });

  it('AC-S5-03: titleContains "sanctions" → severity=high', () => {
    const sig = adapter.normalise(buildRaw('US imposes new sanctions package on Russia'));
    expect(sig.severity).toBe('high');
  });

  it('AC-S5-03: titleContains "force majeure" → severity=medium', () => {
    const sig = adapter.normalise(buildRaw('Force majeure declared on UAE oil shipments'));
    expect(sig.severity).toBe('medium');
  });

  it('event_date populated from isoDate when present', () => {
    const sig = adapter.normalise(buildRaw('Headline', '', '2026-05-09T11:30:00Z'));
    expect(sig.event_date).toBeInstanceOf(Date);
  });

  it('dedup_hash present and 64-char hex', () => {
    const sig = adapter.normalise(buildRaw('Some unique title 12345'));
    expect(sig.dedup_hash.length).toBe(64);
    expect(/^[a-f0-9]+$/.test(sig.dedup_hash)).toBe(true);
  });
});

describe('RssAdapter — fanOutRssAdapters fault isolation', () => {
  it('AC-S5-02 / AC-S5-04: one feed throwing does NOT cascade — siblings still return signals', async () => {
    const okAdapter = new RssAdapter({
      source_id: 'rss_ok',
      url: 'https://example.com/ok',
      source_reliability: 0.85,
    });
    // Override fetch to be a deterministic generator returning 1 raw signal.
    (okAdapter as unknown as { fetch: (since: Date) => AsyncIterator<RawSignal> }).fetch =
      async function* (_since: Date): AsyncIterator<RawSignal> {
        yield {
          payload: {
            title: 'OK feed item',
            link: 'https://example.com/ok/1',
            isoDate: '2026-05-09T00:00:00Z',
            pubDate: '',
            contentSnippet: '',
            guid: 'ok-1',
          },
          fetched_at: new Date('2026-05-09T00:00:00Z'),
        };
      };

    const failingAdapter = new RssAdapter({
      source_id: 'rss_fail',
      url: 'https://example.com/fail',
      source_reliability: 0.85,
    });
    (failingAdapter as unknown as { fetch: (since: Date) => AsyncIterator<RawSignal> }).fetch =
      async function* (_since: Date): AsyncIterator<RawSignal> {
        throw new Error('Mock RSS feed parser blew up');
      };

    const results = await fanOutRssAdapters([okAdapter, failingAdapter], new Date());
    expect(results.length).toBe(2);
    const ok = results.find((r) => r.source_id === 'rss_ok')!;
    const fail = results.find((r) => r.source_id === 'rss_fail')!;
    expect(ok.signals.length).toBe(1);
    expect(ok.error).toBeUndefined();
    expect(fail.signals.length).toBe(0);
    expect(fail.error).toBeDefined();
    expect(fail.error).toContain('Mock RSS feed parser blew up');
  });
});
