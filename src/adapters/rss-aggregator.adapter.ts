/**
 * M7 — RSS Aggregator adapter (CR-A).
 *
 * Wraps the 6 ADNOC Wave-1 RSS sub-feeds (Reuters Energy / Platts / Argus
 * Oil / Lloyd's List / Khaleej Times Business / Gulf News Business). Each
 * sub-feed is registered as a separate osint_source row with source_id
 * `rss_<slug>` (per Annex B.3.5 + seed-data.ts). The fetch worker
 * instantiates one RssAdapter per row (via per-source URL).
 *
 * Critical: AC-S5-04 — one feed failure must NOT cascade. The adapter is
 * single-feed by design; the worker dispatches per-source and isolates
 * exceptions. The aggregator helper at the bottom of this file demonstrates
 * the multi-feed fault-isolation pattern unit tests can exercise.
 *
 * Severity: AC-S5-03 — defaults to 'informational'; high-priority phrases
 * (sanctions / force majeure / port closure) escalate to 'medium' / 'high'
 * per osint_source.severity_mapping rules.
 */
import RssParser from 'rss-parser';
import {
  computeDedupHash,
  type AdapterHealthCheckResult,
  type NormalisedSignal,
  type RateLimitConfig,
  type RawSignal,
  type Severity,
  type SeverityMappingRule,
  type SourceAdapter,
} from './source-adapter';
import { probeReachable } from './fetch-helpers';

interface RssAdapterOptions {
  source_id: string;
  url: string;
  source_reliability: number;
  /** Severity mapping rules from osint_source.severity_mapping. Optional. */
  severity_rules?: SeverityMappingRule[];
}

export class RssAdapter implements SourceAdapter {
  readonly source_id: string;
  readonly source_reliability: number;
  readonly refresh_seconds = 900;
  readonly rate_limit: RateLimitConfig | null = {
    callsPerMinute: 60,
    burst: 10,
    minIntervalMs: 1000,
    respectRetryAfter: true,
  };
  private readonly url: string;
  private readonly severity_rules: SeverityMappingRule[];
  private readonly parser = new RssParser({
    headers: {
      'User-Agent':
        'Mozilla/5.0 (compatible; Musanad-OSINT/1.0; +https://musanad.app)',
      Accept: 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*',
    },
  });

  constructor(opts: RssAdapterOptions) {
    this.source_id = opts.source_id;
    this.url = opts.url;
    this.source_reliability = opts.source_reliability;
    this.severity_rules = opts.severity_rules ?? [];
  }

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    const fetchedAt = new Date();
    // rss-parser handles GET + Atom/RSS auto-detect.
    const feed = await this.parser.parseURL(this.url);
    for (const item of feed.items ?? []) {
      yield {
        payload: {
          title: item.title ?? '',
          link: item.link ?? '',
          isoDate: item.isoDate ?? null,
          pubDate: item.pubDate ?? null,
          contentSnippet: item.contentSnippet ?? '',
          guid: item.guid ?? null,
        },
        fetched_at: fetchedAt,
      };
    }
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const title = String((raw.payload as Record<string, unknown>)['title'] ?? '(untitled)');
    const link = (raw.payload as Record<string, unknown>)['link'];
    const isoDate = (raw.payload as Record<string, unknown>)['isoDate'];
    const summary = String((raw.payload as Record<string, unknown>)['contentSnippet'] ?? '');
    const eventDate = typeof isoDate === 'string' && isoDate.length > 0
      ? new Date(isoDate)
      : undefined;
    const severity = matchSeverity(title, summary, this.severity_rules);
    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      ...(eventDate !== undefined ? { event_date: eventDate } : {}),
      kind: 'news',
      title,
      summary: summary || undefined,
      geographies: [],
      affected_entities: [],
      severity,
      confidence: 0.7,
      url: typeof link === 'string' ? link : undefined,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, eventDate, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    const probe = await probeReachable(this.url);
    if (probe.state === 'healthy') return { state: 'healthy' };
    if (probe.state === 'unauthorised') return { state: 'unauthorised' };
    return { state: 'failing', error: probe.error };
  }
}

/**
 * Apply the severity_mapping rules in order. First match wins. If no rule
 * matches, falls through to default rule (or 'informational').
 *
 * AC-S5-03 — high-priority phrases ('sanctions', 'force majeure', etc.)
 * escalate per configurable rule list.
 */
const matchSeverity = (
  title: string,
  summary: string,
  rules: SeverityMappingRule[],
): Severity => {
  const blob = `${title} ${summary}`.toLowerCase();
  for (const rule of rules) {
    if (rule.titleContains && blob.includes(rule.titleContains.toLowerCase())) {
      return rule.severity ?? 'informational';
    }
  }
  for (const rule of rules) {
    if (rule.default) return rule.default;
  }
  return 'informational';
};

/**
 * Multi-feed fault-isolated dispatcher. Used by the fetch worker when many
 * RSS sub-feeds need to poll on the same cycle. AC-S5-04: one feed failure
 * does NOT cascade — caller receives partial signals + per-feed errors.
 *
 * Public for unit tests.
 */
export interface AggregatedFeedResult {
  source_id: string;
  signals: NormalisedSignal[];
  error?: string;
}

export const fanOutRssAdapters = async (
  adapters: RssAdapter[],
  since: Date,
): Promise<AggregatedFeedResult[]> => {
  return Promise.all(
    adapters.map(async (a): Promise<AggregatedFeedResult> => {
      const signals: NormalisedSignal[] = [];
      try {
        const it = a.fetch(since);
        let next = await it.next();
        while (!next.done) {
          signals.push(a.normalise(next.value));
          next = await it.next();
        }
        return { source_id: a.source_id, signals };
      } catch (err) {
        return {
          source_id: a.source_id,
          signals,
          error: err instanceof Error ? err.message : String(err),
        };
      }
    }),
  );
};
