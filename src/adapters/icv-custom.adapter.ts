/**
 * CR-I — ICV (In-Country Value) custom adapter.
 *
 * Reads from tests/fixtures/osint/mock_icv/*.json on harness trigger.
 * Production variant would call ADNOC ICV registry API; for CR-I scope
 * the fixture-reader mode is the primary path (offline/demo safe).
 *
 * Fixture file format: Array<{ title, summary, event_date?, severity?, url? }>
 */
import { readdir, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import {
  computeDedupHash,
  type AdapterHealthCheckResult,
  type NormalisedSignal,
  type RateLimitConfig,
  type RawSignal,
  type Severity,
  type SourceAdapter,
} from './source-adapter';

const FIXTURE_DIR = resolve(
  process.cwd(),
  'tests/fixtures/osint/mock_icv',
);

interface IcvAdapterOptions {
  source_id: string;
  source_reliability?: number;
  fixtureDir?: string;
}

interface IcvFixtureItem {
  title: string;
  summary?: string;
  event_date?: string;
  severity?: string;
  url?: string;
}

export class IcvCustomAdapter implements SourceAdapter {
  readonly source_id: string;
  readonly source_reliability: number;
  readonly refresh_seconds = 86400;
  readonly rate_limit: RateLimitConfig | null = null;
  private readonly fixtureDir: string;

  constructor(opts: IcvAdapterOptions) {
    this.source_id = opts.source_id;
    this.source_reliability = opts.source_reliability ?? 0.85;
    this.fixtureDir = opts.fixtureDir ?? FIXTURE_DIR;
  }

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    const fetchedAt = new Date();
    const items = await this._loadFixtures();
    for (const item of items) {
      yield { payload: item as unknown as Record<string, unknown>, fetched_at: fetchedAt };
    }
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const p = raw.payload as unknown as IcvFixtureItem;
    const title = p?.title ?? '(untitled ICV signal)';
    const summary = p?.summary ?? '';
    const eventDate = p?.event_date ? new Date(p.event_date) : undefined;
    const severity = this._mapSeverity(p?.severity);

    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      ...(eventDate !== undefined ? { event_date: eventDate } : {}),
      kind: 'regulatory',
      title,
      summary: summary || undefined,
      geographies: [{ isoCountry: 'AE' }],
      affected_entities: [],
      severity,
      confidence: 0.8,
      url: p?.url,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, eventDate, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    try {
      await readdir(this.fixtureDir);
      return { state: 'healthy' };
    } catch {
      // Fixture dir missing is non-critical — returns empty set
      return { state: 'healthy' };
    }
  }

  private async _loadFixtures(): Promise<IcvFixtureItem[]> {
    try {
      const files = await readdir(this.fixtureDir);
      const jsonFiles = files.filter(f => f.endsWith('.json'));
      const allItems: IcvFixtureItem[] = [];
      for (const file of jsonFiles) {
        try {
          const raw = await readFile(join(this.fixtureDir, file), 'utf8');
          const parsed: unknown = JSON.parse(raw);
          if (Array.isArray(parsed)) {
            allItems.push(...(parsed as unknown as IcvFixtureItem[]));
          } else if (typeof parsed === 'object' && parsed !== null) {
            allItems.push(parsed as unknown as IcvFixtureItem);
          }
        } catch {
          // Skip malformed fixture files
        }
      }
      return allItems;
    } catch {
      return [];
    }
  }

  private _mapSeverity(raw: string | undefined): Severity {
    switch ((raw ?? '').toLowerCase()) {
      case 'critical': return 'critical' as Severity;
      case 'high': return 'high';
      case 'medium': return 'medium';
      case 'low': return 'low' as Severity;
      default: return 'informational';
    }
  }
}
