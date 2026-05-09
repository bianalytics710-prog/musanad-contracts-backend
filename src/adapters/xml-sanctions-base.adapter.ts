/**
 * M7 — Shared base for EU / UN / UK consolidated sanctions XML adapters.
 *
 * All three lists ship as monolithic XML feeds with broadly similar shape
 * (root container → array of designation entries with name + program +
 * remarks). CR-A only needs the headline-level signal — title + program +
 * severity='high' (no CAATSA/NSPM-25 carve-out outside OFAC). Subclasses
 * override URL, source_id, and the parser entry-points.
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
import { fetchWithUa, probeReachable } from './fetch-helpers';

const xmlParser = new XMLParser({
  ignoreAttributes: false,
  parseAttributeValue: false,
  trimValues: true,
});

export interface XmlSanctionsEntry {
  uid: string;
  name: string;
  programs: string[];
  remarks?: string;
}

export interface XmlSanctionsAdapterConfig {
  source_id: string;
  source_reliability: number;
  refresh_seconds: number;
  url: string;
  rate_limit: RateLimitConfig | null;
  /** Pluggable parser: receives parsed XML object; returns a flat list. */
  extractEntries: (parsed: Record<string, unknown>) => XmlSanctionsEntry[];
}

export class XmlSanctionsBaseAdapter implements SourceAdapter {
  readonly source_id: string;
  readonly source_reliability: number;
  readonly refresh_seconds: number;
  readonly rate_limit: RateLimitConfig | null;
  protected readonly url: string;
  protected readonly extractEntries: (parsed: Record<string, unknown>) => XmlSanctionsEntry[];

  constructor(cfg: XmlSanctionsAdapterConfig) {
    this.source_id = cfg.source_id;
    this.source_reliability = cfg.source_reliability;
    this.refresh_seconds = cfg.refresh_seconds;
    this.url = cfg.url;
    this.rate_limit = cfg.rate_limit;
    this.extractEntries = cfg.extractEntries;
  }

  /** Public for unit tests. */
  parse(xml: string): XmlSanctionsEntry[] {
    const parsed = xmlParser.parse(xml) as Record<string, unknown>;
    return this.extractEntries(parsed);
  }

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    const fetchedAt = new Date();
    const res = await fetchWithUa(this.url);
    if (!res.ok) {
      throw new Error(`${this.source_id} fetch failed: HTTP ${res.status}`);
    }
    const xml = await res.text();
    const entries = this.parse(xml);
    for (const entry of entries) {
      yield { payload: { ...entry, programs: [...entry.programs] }, fetched_at: fetchedAt };
    }
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const e = raw.payload as unknown as XmlSanctionsEntry;
    const programLabel = e.programs.join(', ') || 'unknown program';
    const title = `${this.titlePrefix()}: ${e.name} (${programLabel})`;
    const severity: Severity = 'high';
    const entity: EntityReference = {
      entityType: 'entity',
      name: e.name,
      identifier: e.uid,
    };
    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      kind: 'sanctions',
      title,
      summary: e.remarks,
      geographies: [],
      affected_entities: [entity],
      severity,
      confidence: 0.95,
      url: this.url,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, undefined, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    const probe = await probeReachable(this.url);
    if (probe.state === 'healthy') return { state: 'healthy' };
    if (probe.state === 'unauthorised') return { state: 'unauthorised' };
    return { state: 'failing', error: probe.error };
  }

  /** Subclass-overridable; default uses source_id capitalised. */
  protected titlePrefix(): string {
    return this.source_id.toUpperCase();
  }
}

const asArray = <T>(v: unknown): T[] => (Array.isArray(v) ? (v as T[]) : v ? [v as T] : []);

export const stringOrEmpty = (v: unknown): string => (v === undefined || v === null ? '' : String(v));

/** Walk an XML tree depth-first, returning the first array-of-objects node
 *  whose key matches `pattern` — convenience helper for sloppy schemas. */
export const firstMatchingArray = (
  root: unknown,
  pattern: RegExp,
): Record<string, unknown>[] => {
  const stack: unknown[] = [root];
  while (stack.length > 0) {
    const node = stack.pop();
    if (!node || typeof node !== 'object') continue;
    const obj = node as Record<string, unknown>;
    for (const [k, v] of Object.entries(obj)) {
      if (pattern.test(k)) {
        const arr = asArray<Record<string, unknown>>(v);
        if (arr.length > 0) return arr;
      }
      if (v && typeof v === 'object') stack.push(v);
    }
  }
  return [];
};
