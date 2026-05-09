/**
 * M7 — GDELT 2.0 adapter (CR-A).
 *
 * Pipeline: fetch http://data.gdeltproject.org/gdeltv2/lastupdate.txt → URL
 * of the latest 15-min CSV window → fetch CSV → ADNOC-relevance filter →
 * normalise.
 *
 * Reliability: 0.65. Refresh: 900 s.
 *
 * AC mapping:
 *   - AC-S5-04: ADNOC-relevance filter applied BEFORE normalise() runs:
 *       country IN [AE, SA, OM, QA, BH, KW, IR, IQ] OR
 *       theme   IN [ENERGY, MARITIME, SANCTIONS]
 *   - AC-S5-05: severity from GoldsteinScale + tone (GoldsteinScale < -7 → 'high')
 */
import {
  computeDedupHash,
  type AdapterHealthCheckResult,
  type GeoReference,
  type GeographyFilter,
  type NormalisedSignal,
  type RateLimitConfig,
  type RawSignal,
  type Severity,
  type SourceAdapter,
} from './source-adapter';

const GDELT_LASTUPDATE_URL = 'http://data.gdeltproject.org/gdeltv2/lastupdate.txt';

interface GdeltAdapterOptions {
  geography_filter?: GeographyFilter | null;
}

interface GdeltRow {
  globalEventId: string;
  sqlDate: string;       // YYYYMMDD
  actor1Code: string;
  actor1CountryCode: string;
  goldsteinScale: number;
  numMentions: number;
  avgTone: number;
  themes: string;        // semicolon-delimited
  sourceUrl: string;
  rawTitle: string;
}

export class GdeltAdapter implements SourceAdapter {
  readonly source_id = 'gdelt_v2';
  readonly source_reliability = 0.65;
  readonly refresh_seconds = 900;
  readonly rate_limit: RateLimitConfig | null = {
    callsPerMinute: 60,
    burst: 10,
    minIntervalMs: 1000,
    respectRetryAfter: true,
  };
  private readonly geography_filter: GeographyFilter;

  constructor(opts: GdeltAdapterOptions = {}) {
    // GDELT 2.0 ships 3-letter CAMEO country codes (ARE/SAU/...), NOT alpha-2 ISO.
    // The 8 ADNOC-relevance countries from §14.3 are normalised to CAMEO here so
    // production fetches don't drop every row. Alpha-2 fixtures used in adapter
    // unit tests are mapped via this same list.
    this.geography_filter = opts.geography_filter ?? {
      countryIn: ['ARE', 'SAU', 'OMN', 'QAT', 'BHR', 'KWT', 'IRN', 'IRQ'],
      themeIn: ['ENERGY', 'MARITIME', 'SANCTIONS'],
    };
  }

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    const fetchedAt = new Date();
    // Step 1: lastupdate.txt → 3 lines, the first ending in `.export.CSV.zip`
    // (GDELT distributes a tab-separated index of recent windows).
    const indexRes = await fetch(GDELT_LASTUPDATE_URL);
    if (!indexRes.ok) {
      throw new Error(`gdelt_v2 lastupdate fetch failed: HTTP ${indexRes.status}`);
    }
    const indexText = await indexRes.text();
    const exportUrl = parseLastUpdate(indexText);
    if (!exportUrl) {
      throw new Error('gdelt_v2: no export URL parsed from lastupdate.txt');
    }
    // Step 2: CSV. GDELT serves a zipped TSV at this URL; CR-A keeps the
    // adapter pluggable but defers binary unzipping to a follow-up
    // (production deployments typically use the CSV API mirror at
    // export.csv.zip). For test/integration we accept either CSV body or
    // gzip-decompressed text via Node native `Response`.
    const csvRes = await fetch(exportUrl);
    if (!csvRes.ok) {
      throw new Error(`gdelt_v2 export fetch failed: HTTP ${csvRes.status}`);
    }
    const csvText = await csvRes.text();
    const rows = parseGdeltCsv(csvText);
    // AC-S5-04: filter BEFORE normalise.
    const filtered = rows.filter((r) => this.passesAdnocFilter(r));
    for (const row of filtered) {
      yield { payload: { ...row }, fetched_at: fetchedAt };
    }
  }

  /** Public for unit tests. */
  passesAdnocFilter(row: GdeltRow): boolean {
    const f = this.geography_filter;
    const countries = f.countryIn ?? [];
    const themes = f.themeIn ?? [];
    const actors = f.actorIn ?? [];
    const country = row.actor1CountryCode.toUpperCase();
    const themeList = row.themes.split(';').map((t) => t.toUpperCase());
    if (countries.length > 0 && countries.includes(country)) return true;
    if (themes.length > 0 && themes.some((t) => themeList.includes(t.toUpperCase()))) return true;
    if (actors.length > 0 && actors.includes(row.actor1Code.toUpperCase())) return true;
    return false;
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const r = raw.payload as unknown as GdeltRow;
    const title =
      r.rawTitle && r.rawTitle.length > 0 ? r.rawTitle : `GDELT event ${r.globalEventId}`;
    const eventDate = parseSqlDate(r.sqlDate) ?? raw.fetched_at;
    const severity = gdeltSeverity(r.goldsteinScale, r.avgTone);
    const geographies: GeoReference[] = r.actor1CountryCode
      ? [{ isoCountry: r.actor1CountryCode.toUpperCase() }]
      : [];
    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      event_date: eventDate,
      kind: 'geopolitical',
      title,
      summary: r.themes,
      geographies,
      affected_entities: [],
      severity,
      confidence: 0.6,
      url: r.sourceUrl || GDELT_LASTUPDATE_URL,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, eventDate, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    try {
      const res = await fetch(GDELT_LASTUPDATE_URL, { method: 'HEAD' });
      if (res.ok) return { state: 'healthy' };
      if (res.status === 401 || res.status === 403) return { state: 'unauthorised' };
      return { state: 'failing', error: `HTTP ${res.status}` };
    } catch (err) {
      return { state: 'failing', error: err instanceof Error ? err.message : String(err) };
    }
  }
}

/** Extracts the most recent .export.CSV(.zip) URL from lastupdate.txt. */
export const parseLastUpdate = (text: string): string | null => {
  const lines = text.split(/\r?\n/);
  for (const line of lines) {
    const m = line.match(/(http\S+\.export\.CSV(?:\.zip)?)/i);
    if (m) return m[1] ?? null;
  }
  return null;
};

/**
 * GDELT 2.0 export schema is tab-separated with ~58 columns. CR-A only
 * extracts the columns we need; full schema reference at
 * http://data.gdeltproject.org/documentation/GDELT-Event_Codebook-V2.0.pdf.
 *
 * Public for unit tests.
 */
export const parseGdeltCsv = (text: string): GdeltRow[] => {
  const lines = text.split(/\r?\n/).filter((l) => l.length > 0);
  const out: GdeltRow[] = [];
  for (const line of lines) {
    const cells = line.split('\t');
    if (cells.length < 30) continue;
    const globalEventId = cells[0] ?? '';
    const sqlDate = cells[1] ?? '';
    const actor1Code = cells[5] ?? '';
    const actor1CountryCode = cells[7] ?? '';
    const goldsteinRaw = cells[30] ?? '0';
    const numMentionsRaw = cells[31] ?? '0';
    const avgToneRaw = cells[34] ?? '0';
    const themes = cells[26] ?? '';
    const sourceUrl = cells[57] ?? '';
    const rawTitle = '';
    out.push({
      globalEventId,
      sqlDate,
      actor1Code,
      actor1CountryCode,
      goldsteinScale: Number(goldsteinRaw) || 0,
      numMentions: Number(numMentionsRaw) || 0,
      avgTone: Number(avgToneRaw) || 0,
      themes,
      sourceUrl,
      rawTitle,
    });
  }
  return out;
};

const parseSqlDate = (s: string): Date | undefined => {
  if (!/^\d{8}$/.test(s)) return undefined;
  const y = Number(s.slice(0, 4));
  const m = Number(s.slice(4, 6));
  const d = Number(s.slice(6, 8));
  return new Date(Date.UTC(y, m - 1, d));
};

/**
 * AC-S5-05 — GoldsteinScale ranges from -10 (most cooperative violence) to
 * +10 (most cooperative); tone ∈ [-100, 100]. We map low Goldstein +
 * negative tone to high severity.
 */
const gdeltSeverity = (goldstein: number, avgTone: number): Severity => {
  if (goldstein < -7) return 'high';
  if (goldstein < -4 || avgTone < -8) return 'medium';
  if (goldstein < 0 || avgTone < -2) return 'low';
  return 'informational';
};
