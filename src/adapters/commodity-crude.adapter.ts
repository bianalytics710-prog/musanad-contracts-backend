/**
 * M7 — Commodity Crude (Brent / Dubai / Murban / WTI) adapter (CR-A).
 *
 * Provider: oilpriceapi.com free tier (per Q-NEW1 lock).
 * URL: https://api.oilpriceapi.com/v1/prices/latest
 * Refresh: 300 s. Reliability: 0.90.
 * Markers: BRENT, DUBAI, MURBAN, WTI.
 *
 * AC mapping:
 *   - AC-S6-01: 4 markers, 5-min cadence
 *   - AC-S6-02: severity per absChangePctGte rules from severity_mapping
 *   - AC-S6-05: credential_ref='env:COMMODITY_API_KEY'; missing key →
 *               health_check state='unauthorised'
 */
import { resolveCredential } from './source-adapter';
import type {
  AdapterHealthCheckResult,
  EntityReference,
  NormalisedSignal,
  RateLimitConfig,
  RawSignal,
  Severity,
  SeverityMappingRule,
  SourceAdapter,
} from './source-adapter';
import { computeDedupHash } from './source-adapter';

const COMMODITY_URL = 'https://api.oilpriceapi.com/v1/prices/latest';
const MARKERS = ['BRENT', 'DUBAI', 'MURBAN', 'WTI'] as const;
type Marker = (typeof MARKERS)[number];

interface CommodityPriceRecord {
  marker: Marker;
  price: number;
  changePct24h: number;
  observedAt: string;
}

interface CommodityAdapterOptions {
  /** osint_source.source_credential.credential_ref (e.g. 'env:COMMODITY_API_KEY'). */
  credential_ref?: string | null;
  severity_rules?: SeverityMappingRule[];
}

export class CommodityCrudeAdapter implements SourceAdapter {
  readonly source_id = 'commodity_crude';
  readonly source_reliability = 0.9;
  readonly refresh_seconds = 300;
  readonly rate_limit: RateLimitConfig | null = {
    callsPerMinute: 12,
    burst: 2,
    minIntervalMs: 5_000,
    respectRetryAfter: true,
  };
  private readonly credential_ref: string | null;
  private readonly severity_rules: SeverityMappingRule[];

  constructor(opts: CommodityAdapterOptions = {}) {
    this.credential_ref = opts.credential_ref ?? null;
    this.severity_rules = opts.severity_rules ?? [
      { absChangePctGte: 5, severity: 'high' },
      { absChangePctGte: 2, severity: 'medium' },
      { default: 'informational' },
    ];
  }

  private resolveApiKey(): string | undefined {
    return resolveCredential(this.credential_ref);
  }

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    const fetchedAt = new Date();
    const apiKey = this.resolveApiKey();
    if (!apiKey) {
      throw new Error('commodity_crude: missing API key (credential unresolved)');
    }
    const headers: Record<string, string> = { Authorization: `Token ${apiKey}` };
    // The free-tier endpoint returns latest prices for all markers; per-marker
    // filtering is done client-side. Schema can vary — we treat the response
    // as opaque JSON and yield one RawSignal per marker we recognise.
    const res = await fetch(COMMODITY_URL, { headers });
    if (!res.ok) {
      throw new Error(`commodity_crude fetch failed: HTTP ${res.status}`);
    }
    const data = (await res.json()) as Record<string, unknown>;
    const records = parseCommodityResponse(data);
    for (const r of records) {
      yield {
        payload: { ...r },
        fetched_at: fetchedAt,
      };
    }
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const r = raw.payload as unknown as CommodityPriceRecord;
    const title = `${r.marker} crude price ${r.price.toFixed(2)} USD (${
      r.changePct24h >= 0 ? '+' : ''
    }${r.changePct24h.toFixed(2)}% 24h)`;
    const eventDate = r.observedAt ? new Date(r.observedAt) : undefined;
    const severity = matchCommoditySeverity(r.changePct24h, this.severity_rules);
    const entity: EntityReference = {
      entityType: 'instrument',
      name: `${r.marker} crude`,
      identifier: r.marker,
    };
    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      ...(eventDate !== undefined ? { event_date: eventDate } : {}),
      kind: 'commodity',
      title,
      summary: undefined,
      geographies: [],
      affected_entities: [entity],
      severity,
      confidence: 0.85,
      url: COMMODITY_URL,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, eventDate, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    const apiKey = this.resolveApiKey();
    if (!apiKey) {
      // AC-S6-05 — missing env var resolves to unauthorised.
      return { state: 'unauthorised', error: 'COMMODITY_API_KEY env var not set' };
    }
    try {
      const res = await fetch(COMMODITY_URL, {
        method: 'HEAD',
        headers: { Authorization: `Token ${apiKey}` },
      });
      if (res.ok) return { state: 'healthy' };
      if (res.status === 401 || res.status === 403) return { state: 'unauthorised' };
      return { state: 'failing', error: `HTTP ${res.status}` };
    } catch (err) {
      return { state: 'failing', error: err instanceof Error ? err.message : String(err) };
    }
  }
}

/** Public for unit tests. */
export const parseCommodityResponse = (data: unknown): CommodityPriceRecord[] => {
  // oilpriceapi returns either { data: [...] } or { prices: [...] } depending
  // on tier; treat both leniently.
  const root = data as Record<string, unknown>;
  const list = (root['data'] ?? root['prices']) as unknown;
  const arr = Array.isArray(list) ? list : [];
  return arr
    .map((row): CommodityPriceRecord | null => {
      const r = row as Record<string, unknown>;
      const code = String(r['code'] ?? r['marker'] ?? r['symbol'] ?? '').toUpperCase();
      if (!MARKERS.includes(code as Marker)) return null;
      const priceRaw = r['price'] ?? r['value'] ?? r['close'];
      const price = typeof priceRaw === 'number' ? priceRaw : Number(priceRaw);
      if (!Number.isFinite(price)) return null;
      const changeRaw = r['changePct24h'] ?? r['change_percent'] ?? r['percent_change'] ?? 0;
      const change = typeof changeRaw === 'number' ? changeRaw : Number(changeRaw);
      const observedAt = String(
        r['observedAt'] ?? r['observed_at'] ?? r['timestamp'] ?? new Date().toISOString(),
      );
      return {
        marker: code as Marker,
        price,
        changePct24h: Number.isFinite(change) ? change : 0,
        observedAt,
      };
    })
    .filter((r): r is CommodityPriceRecord => r !== null);
};

const matchCommoditySeverity = (
  changePct24h: number,
  rules: SeverityMappingRule[],
): Severity => {
  const abs = Math.abs(changePct24h);
  for (const rule of rules) {
    if (typeof rule.absChangePctGte === 'number' && abs >= rule.absChangePctGte) {
      return rule.severity ?? 'informational';
    }
  }
  for (const rule of rules) {
    if (rule.default) return rule.default;
  }
  return 'informational';
};
