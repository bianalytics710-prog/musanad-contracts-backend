/**
 * M7 — USD/AED FX adapter (CR-A).
 *
 * Primary: https://open.er-api.com/v6/latest/USD (no key, free tier).
 * Fallback: https://api.exchangerate.host/latest (now requires API key as
 *   of 2026; left as fallback in case caller has EXCHANGERATE_API_KEY).
 * Original Q-NEW2 lock recommended exchangerate.host primary; reordered
 * 2026-05-09 after exchangerate.host migrated to a paid model and started
 * returning {success:false, error: missing_access_key} for unauth GETs.
 * Refresh: 300 s. Reliability: 0.85.
 * Pairs: USD/AED, USD/EUR, USD/GBP, USD/INR.
 *
 * AC-S6-04 — peg deviation severity:
 *   abs((rate - 3.6725) / 3.6725) > 0.5%  → 'high'
 *   abs(deviation)                  > 0.25% → 'medium'
 *   else                                   → 'informational'
 */
import {
  computeDedupHash,
  type AdapterHealthCheckResult,
  type EntityReference,
  type NormalisedSignal,
  type RateLimitConfig,
  type RawSignal,
  type Severity,
  type SeverityMappingRule,
  type SourceAdapter,
} from './source-adapter';
import { fetchWithUa, probeReachable } from './fetch-helpers';

// Reordered 2026-05-09: open.er-api.com is the working free-tier primary;
// exchangerate.host now requires a paid API key. Both are still tried
// (primary then fallback) so the adapter is provider-agnostic.
const FX_PRIMARY_URL = 'https://open.er-api.com/v6/latest/USD';
const FX_FALLBACK_URL = 'https://api.exchangerate.host/latest';

const PAIRS = ['AED', 'EUR', 'GBP', 'INR'] as const;
type Pair = (typeof PAIRS)[number];

const AED_PEG = 3.6725;

interface FxRecord {
  pair: Pair;
  rate: number;
  base: 'USD';
  observedAt: string;
  /** Provider used to populate this record. */
  provider: 'exchangerate.host' | 'open.er-api.com';
}

interface FxAdapterOptions {
  severity_rules?: SeverityMappingRule[];
}

export class FxAdapter implements SourceAdapter {
  readonly source_id = 'fx_usd_aed';
  readonly source_reliability = 0.85;
  readonly refresh_seconds = 300;
  readonly rate_limit: RateLimitConfig | null = {
    callsPerMinute: 12,
    burst: 2,
    minIntervalMs: 5_000,
    respectRetryAfter: true,
  };
  private readonly severity_rules: SeverityMappingRule[];

  constructor(opts: FxAdapterOptions = {}) {
    this.severity_rules = opts.severity_rules ?? [
      { pegDeviationPctGte: 0.5, severity: 'high' },
      { pegDeviationPctGte: 0.25, severity: 'medium' },
      { default: 'informational' },
    ];
  }

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    const fetchedAt = new Date();
    const records = await this.fetchRates();
    for (const r of records) {
      yield { payload: { ...r }, fetched_at: fetchedAt };
    }
  }

  /** Public for unit tests. Tries primary (open.er-api) then fallback (exchangerate.host). */
  async fetchRates(): Promise<FxRecord[]> {
    try {
      const res = await fetchWithUa(FX_PRIMARY_URL);
      if (res.ok) {
        const data = (await res.json()) as Record<string, unknown>;
        const parsed = parseOpenErApi(data);
        if (parsed.length > 0) return parsed;
      }
    } catch {
      // fall through to fallback
    }
    const res = await fetchWithUa(FX_FALLBACK_URL);
    if (!res.ok) {
      throw new Error(`fx_usd_aed both providers failed: HTTP ${res.status}`);
    }
    const data = (await res.json()) as Record<string, unknown>;
    const parsed = parseExchangerateHost(data);
    if (parsed.length === 0) {
      throw new Error('fx_usd_aed: fallback returned no rates (likely missing API key)');
    }
    return parsed;
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const r = raw.payload as unknown as FxRecord;
    const eventDate = r.observedAt ? new Date(r.observedAt) : undefined;
    const severity =
      r.pair === 'AED' ? matchPegSeverity(r.rate, AED_PEG, this.severity_rules) : 'informational';
    const title = `USD/${r.pair} ${r.rate.toFixed(4)}${
      r.pair === 'AED' ? ` (peg deviation ${pegDeviationPct(r.rate, AED_PEG).toFixed(3)}%)` : ''
    }`;
    const entity: EntityReference = {
      entityType: 'instrument',
      name: `USD/${r.pair}`,
      identifier: `USD_${r.pair}`,
    };
    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      ...(eventDate !== undefined ? { event_date: eventDate } : {}),
      kind: 'fx',
      title,
      summary: `provider=${r.provider}`,
      geographies: [],
      affected_entities: [entity],
      severity,
      confidence: 0.85,
      url: r.provider === 'open.er-api.com' ? FX_PRIMARY_URL : FX_FALLBACK_URL,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, eventDate, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    const probe = await probeReachable(FX_PRIMARY_URL);
    if (probe.state === 'healthy') return { state: 'healthy' };
    if (probe.state === 'unauthorised') return { state: 'unauthorised' };
    return { state: 'failing', error: probe.error };
  }
}

const pegDeviationPct = (rate: number, peg: number): number =>
  Math.abs(((rate - peg) / peg) * 100);

const matchPegSeverity = (
  rate: number,
  peg: number,
  rules: SeverityMappingRule[],
): Severity => {
  const devPct = pegDeviationPct(rate, peg);
  for (const rule of rules) {
    if (typeof rule.pegDeviationPctGte === 'number' && devPct >= rule.pegDeviationPctGte) {
      return rule.severity ?? 'informational';
    }
  }
  for (const rule of rules) {
    if (rule.default) return rule.default;
  }
  return 'informational';
};

/** Public for unit tests. */
export const parseExchangerateHost = (data: Record<string, unknown>): FxRecord[] => {
  const rates = data['rates'] as Record<string, number> | undefined;
  if (!rates) return [];
  const date = String(data['date'] ?? new Date().toISOString().slice(0, 10));
  const out: FxRecord[] = [];
  for (const p of PAIRS) {
    const v = rates[p];
    if (typeof v !== 'number' || !Number.isFinite(v)) continue;
    out.push({
      pair: p,
      rate: v,
      base: 'USD',
      observedAt: `${date}T00:00:00Z`,
      provider: 'exchangerate.host',
    });
  }
  return out;
};

/** Public for unit tests. */
export const parseOpenErApi = (data: Record<string, unknown>): FxRecord[] => {
  const rates = data['rates'] as Record<string, number> | undefined;
  if (!rates) return [];
  const tsRaw = data['time_last_update_utc'];
  const ts =
    typeof tsRaw === 'string' ? new Date(tsRaw).toISOString() : new Date().toISOString();
  const out: FxRecord[] = [];
  for (const p of PAIRS) {
    const v = rates[p];
    if (typeof v !== 'number' || !Number.isFinite(v)) continue;
    out.push({
      pair: p,
      rate: v,
      base: 'USD',
      observedAt: ts,
      provider: 'open.er-api.com',
    });
  }
  return out;
};
