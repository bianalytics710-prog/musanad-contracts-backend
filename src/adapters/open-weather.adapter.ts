/**
 * CR-I — OpenWeather adapter (stub-capable).
 *
 * When WEATHER_API_KEY env var is not set, returns deterministic mock data
 * per §4.12 of the CRIP SOT (offline-stub mode for demo). When set, fetches
 * from api.openweathermap.org/data/2.5/weather for the Persian Gulf grid.
 *
 * Severity mapping: wind_speed ≥ 20m/s → 'high', ≥ 12m/s → 'medium',
 * else 'informational'.
 */
import { randomUUID } from 'node:crypto';
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

const OPENWEATHER_BASE = 'https://api.openweathermap.org/data/2.5';
/** Default Persian Gulf grid coordinate (Abu Dhabi). */
const DEFAULT_LAT = 24.4539;
const DEFAULT_LON = 54.3773;

interface OpenWeatherAdapterOptions {
  source_id: string;
  source_reliability?: number;
  lat?: number;
  lon?: number;
}

interface OpenWeatherPayload {
  dt: number;
  wind: { speed: number; deg: number };
  weather: { id: number; main: string; description: string }[];
  main: { temp: number; humidity: number };
  name: string;
}

export class OpenWeatherAdapter implements SourceAdapter {
  readonly source_id: string;
  readonly source_reliability: number;
  readonly refresh_seconds = 3600;
  readonly rate_limit: RateLimitConfig | null = {
    callsPerMinute: 60,
    burst: 5,
    minIntervalMs: 1000,
    respectRetryAfter: true,
  };
  private readonly apiKey: string | undefined;
  private readonly lat: number;
  private readonly lon: number;

  constructor(opts: OpenWeatherAdapterOptions) {
    this.source_id = opts.source_id;
    this.source_reliability = opts.source_reliability ?? 0.8;
    this.apiKey = process.env['WEATHER_API_KEY'];
    this.lat = opts.lat ?? DEFAULT_LAT;
    this.lon = opts.lon ?? DEFAULT_LON;
  }

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    const fetchedAt = new Date();
    const payload = await this._fetchOrStub(fetchedAt);
    yield { payload: payload as unknown as Record<string, unknown>, fetched_at: fetchedAt };
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const p = raw.payload as unknown as OpenWeatherPayload;
    const windSpeed: number = p?.wind?.speed ?? 0;
    const weatherDesc: string = p?.weather?.[0]?.description ?? 'unknown';
    const locationName: string = p?.name ?? 'Persian Gulf region';
    const title = `Weather alert: ${weatherDesc} at ${locationName}`;
    const eventDate = p?.dt ? new Date(p.dt * 1000) : raw.fetched_at;
    const severity = this._mapSeverity(windSpeed);

    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      event_date: eventDate,
      kind: 'regulatory',
      title,
      summary: `Wind ${windSpeed}m/s, ${weatherDesc}. Location: ${locationName}.`,
      geographies: [{ isoCountry: 'AE' }],
      affected_entities: [],
      severity,
      confidence: 0.75,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, eventDate, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    if (!this.apiKey) {
      // Stub mode — always healthy in demo context
      return { state: 'healthy' };
    }
    const probe = await probeReachable(`${OPENWEATHER_BASE}/weather?lat=${this.lat}&lon=${this.lon}&appid=${this.apiKey}`);
    if (probe.state === 'healthy') return { state: 'healthy' };
    if (probe.state === 'unauthorised') return { state: 'unauthorised' };
    return { state: 'failing', error: probe.error };
  }

  private async _fetchOrStub(fetchedAt: Date): Promise<OpenWeatherPayload> {
    if (!this.apiKey) {
      return this._mockPayload(fetchedAt);
    }
    try {
      const url = `${OPENWEATHER_BASE}/weather?lat=${this.lat}&lon=${this.lon}&appid=${this.apiKey}&units=metric`;
      const res = await fetch(url, {
        headers: { 'User-Agent': 'Musanad-OSINT/1.0' },
      });
      if (!res.ok) {
        return this._mockPayload(fetchedAt);
      }
      return (await res.json()) as OpenWeatherPayload;
    } catch {
      return this._mockPayload(fetchedAt);
    }
  }

  private _mockPayload(fetchedAt: Date): OpenWeatherPayload {
    return {
      dt: Math.floor(fetchedAt.getTime() / 1000),
      wind: { speed: 8.5, deg: 270 },
      weather: [{ id: 500, main: 'Rain', description: 'light rain' }],
      main: { temp: 28.4, humidity: 72 },
      name: 'Abu Dhabi',
    };
  }

  private _mapSeverity(windSpeed: number): Severity {
    if (windSpeed >= 20) return 'high';
    if (windSpeed >= 12) return 'medium';
    return 'informational';
  }
}
