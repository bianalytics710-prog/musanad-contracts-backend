/**
 * CR-I — Open-Meteo adapter for Persian Gulf grid (NOAA proxy decision CR-I-Q1).
 *
 * Open-Meteo is an open-source weather API with no API key required; used as
 * the NOAA proxy for Persian Gulf forecast data (Gulf coordinates).
 *
 * No API key required — always online-capable with stub fallback on fetch error.
 *
 * Grid: Persian Gulf centre point (26.0°N, 55.0°E) per CR-I-Q1 decision.
 *
 * Severity: windspeed_10m (km/h) ≥ 50 → 'high', ≥ 30 → 'medium', else 'informational'.
 */
import {
  computeDedupHash,
  type AdapterHealthCheckResult,
  type NormalisedSignal,
  type RateLimitConfig,
  type RawSignal,
  type Severity,
  type SourceAdapter,
} from './source-adapter';
import { probeReachable } from './fetch-helpers';

const OPEN_METEO_BASE = 'https://api.open-meteo.com/v1/forecast';
/** Persian Gulf centre point (CR-I-Q1) */
const GULF_LAT = 26.0;
const GULF_LON = 55.0;

interface OpenMeteoAdapterOptions {
  source_id: string;
  source_reliability?: number;
  lat?: number;
  lon?: number;
}

interface OpenMeteoHourlyPayload {
  hourly: {
    time: string[];
    windspeed_10m: number[];
    weathercode: number[];
  };
  latitude: number;
  longitude: number;
}

export class OpenMeteoNoaaAdapter implements SourceAdapter {
  readonly source_id: string;
  readonly source_reliability: number;
  readonly refresh_seconds = 3600;
  readonly rate_limit: RateLimitConfig | null = {
    callsPerMinute: 60,
    burst: 10,
    minIntervalMs: 1000,
    respectRetryAfter: true,
  };
  private readonly lat: number;
  private readonly lon: number;

  constructor(opts: OpenMeteoAdapterOptions) {
    this.source_id = opts.source_id;
    this.source_reliability = opts.source_reliability ?? 0.75;
    this.lat = opts.lat ?? GULF_LAT;
    this.lon = opts.lon ?? GULF_LON;
  }

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    const fetchedAt = new Date();
    const payload = await this._fetchOrStub(fetchedAt);
    yield { payload: payload as unknown as Record<string, unknown>, fetched_at: fetchedAt };
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const p = raw.payload as unknown as OpenMeteoHourlyPayload;
    // Take the first hourly entry as the "current" reading
    const windspeed = p?.hourly?.windspeed_10m?.[0] ?? 0;
    const weatherCode = p?.hourly?.weathercode?.[0] ?? 0;
    const timeStr = p?.hourly?.time?.[0] ?? raw.fetched_at.toISOString();
    const eventDate = new Date(timeStr);
    const severity = this._mapSeverity(windspeed);
    const title = `Persian Gulf forecast: windspeed ${windspeed} km/h, WMO code ${weatherCode}`;

    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      event_date: eventDate,
      kind: 'regulatory',
      title,
      summary: `Open-Meteo NOAA-proxy forecast at lat=${p?.latitude ?? this.lat}, lon=${p?.longitude ?? this.lon}. Wind: ${windspeed} km/h.`,
      geographies: [{ isoCountry: 'AE' }],
      affected_entities: [],
      severity,
      confidence: 0.7,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, eventDate, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    const probe = await probeReachable(`${OPEN_METEO_BASE}?latitude=${this.lat}&longitude=${this.lon}&hourly=windspeed_10m&forecast_days=1`);
    if (probe.state === 'healthy') return { state: 'healthy' };
    if (probe.state === 'unauthorised') return { state: 'unauthorised' };
    return { state: 'failing', error: (probe as { error?: string }).error ?? 'unreachable' };
  }

  private async _fetchOrStub(fetchedAt: Date): Promise<OpenMeteoHourlyPayload> {
    try {
      const url = `${OPEN_METEO_BASE}?latitude=${this.lat}&longitude=${this.lon}&hourly=windspeed_10m,weathercode&forecast_days=1`;
      const res = await fetch(url, {
        headers: { 'User-Agent': 'Musanad-OSINT/1.0' },
      });
      if (res.ok) {
        return (await res.json()) as OpenMeteoHourlyPayload;
      }
    } catch {
      // Fall through to stub
    }
    return this._mockPayload(fetchedAt);
  }

  private _mockPayload(fetchedAt: Date): OpenMeteoHourlyPayload {
    return {
      latitude: this.lat,
      longitude: this.lon,
      hourly: {
        time: [fetchedAt.toISOString()],
        windspeed_10m: [18.5],
        weathercode: [2],
      },
    };
  }

  private _mapSeverity(windspeedKmh: number): Severity {
    if (windspeedKmh >= 50) return 'high';
    if (windspeedKmh >= 30) return 'medium';
    return 'informational';
  }
}
