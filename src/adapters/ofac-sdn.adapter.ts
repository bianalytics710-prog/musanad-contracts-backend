/**
 * M7 — OFAC SDN sanctions adapter (CR-A).
 *
 * URL: https://www.treasury.gov/ofac/downloads/sdn.xml
 * Refresh: 86400 s (daily). Reliability: 1.0.
 * Severity: program contains 'CAATSA' or 'NSPM-25' → critical; else high.
 *
 * AC mapping:
 *   - AC-S4-02: source_reliability=1.0, refresh_seconds=86400
 *   - AC-S4-03: severity rules (CAATSA/NSPM-25 → critical; else high)
 *   - AC-S4-04: dedup_hash via SHA-256 makes re-fetch idempotent
 *   - AC-S4-05: health_check returns healthy/200, unauthorised/401-403,
 *               failing/5xx-network
 */
import { XMLParser } from 'fast-xml-parser';
import {
  computeDedupHash,
  type AdapterHealthCheckResult,
  type EntityReference,
  type NormalisedSignal,
  type RateLimitConfig,
  type RawSignal,
  type Severity,
  type SourceAdapter,
} from './source-adapter';

const OFAC_SDN_URL = 'https://www.treasury.gov/ofac/downloads/sdn.xml';

interface SdnEntry {
  uid: string;
  firstName?: string;
  lastName?: string;
  sdnType?: string;
  programs: string[];
  remarks?: string;
}

const xmlParser = new XMLParser({
  ignoreAttributes: false,
  parseAttributeValue: false,
  trimValues: true,
});

/** Public so unit tests can call directly with fixture XML. */
export const parseOfacXml = (xml: string): SdnEntry[] => {
  const parsed = xmlParser.parse(xml) as Record<string, unknown>;
  const root = (parsed['sdnList'] ?? parsed['SDNList']) as Record<string, unknown> | undefined;
  if (!root) return [];
  const entries = root['sdnEntry'] ?? root['SDNEntry'];
  const list = Array.isArray(entries) ? entries : entries ? [entries] : [];
  return list.map((raw): SdnEntry => {
    const e = raw as Record<string, unknown>;
    const programList = (e['programList'] ?? e['ProgramList']) as
      | Record<string, unknown>
      | undefined;
    const program = programList?.['program'];
    const programs = Array.isArray(program)
      ? program.map((p) => String(p))
      : program
        ? [String(program)]
        : [];
    return {
      uid: String(e['uid'] ?? e['UID'] ?? ''),
      firstName: e['firstName'] !== undefined ? String(e['firstName']) : undefined,
      lastName: e['lastName'] !== undefined ? String(e['lastName']) : undefined,
      sdnType: e['sdnType'] !== undefined ? String(e['sdnType']) : undefined,
      programs,
      remarks: e['remarks'] !== undefined ? String(e['remarks']) : undefined,
    };
  });
};

const sdnSeverity = (programs: string[]): Severity => {
  for (const p of programs) {
    if (p.toUpperCase().includes('CAATSA')) return 'critical';
    if (p.toUpperCase().includes('NSPM-25')) return 'critical';
  }
  return 'high';
};

/**
 * Build a synthetic title from SDN fields. Falls back to UID if name fields
 * are absent (entities, vessels, etc).
 */
const sdnTitle = (e: SdnEntry): string => {
  const nameParts = [e.firstName, e.lastName].filter((p): p is string => !!p);
  const name = nameParts.join(' ').trim();
  return name.length > 0
    ? `OFAC SDN: ${name} (${e.programs.join(', ') || 'unknown program'})`
    : `OFAC SDN: UID ${e.uid} (${e.programs.join(', ') || 'unknown program'})`;
};

const sdnEntityRef = (e: SdnEntry): EntityReference => ({
  entityType: (e.sdnType ?? 'company').toLowerCase(),
  name:
    [e.firstName, e.lastName].filter(Boolean).join(' ').trim() || `SDN-${e.uid}`,
  identifier: e.uid,
});

export class OfacSdnAdapter implements SourceAdapter {
  readonly source_id = 'ofac_sdn';
  readonly source_reliability = 1.0;
  readonly refresh_seconds = 86400;
  readonly rate_limit: RateLimitConfig | null = {
    callsPerMinute: 1,
    burst: 1,
    minIntervalMs: 60_000,
    respectRetryAfter: true,
  };

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    const fetchedAt = new Date();
    const res = await fetch(OFAC_SDN_URL);
    if (!res.ok) {
      throw new Error(`OFAC SDN fetch failed: HTTP ${res.status}`);
    }
    const xml = await res.text();
    const entries = parseOfacXml(xml);
    for (const entry of entries) {
      yield {
        payload: { ...entry, programs: [...entry.programs] },
        fetched_at: fetchedAt,
      };
    }
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const e = raw.payload as unknown as SdnEntry;
    const title = sdnTitle(e);
    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      kind: 'sanctions',
      title,
      summary: e.remarks,
      geographies: [],
      affected_entities: [sdnEntityRef(e)],
      severity: sdnSeverity(e.programs),
      confidence: 0.95,
      url: OFAC_SDN_URL,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, undefined, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    try {
      const res = await fetch(OFAC_SDN_URL, { method: 'HEAD' });
      if (res.ok) return { state: 'healthy' };
      if (res.status === 401 || res.status === 403) return { state: 'unauthorised' };
      return { state: 'failing', error: `HTTP ${res.status}` };
    } catch (err) {
      return {
        state: 'failing',
        error: err instanceof Error ? err.message : String(err),
      };
    }
  }
}
