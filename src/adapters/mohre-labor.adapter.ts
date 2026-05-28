/**
 * CR-M — MOHRE Labor-Law adapter.
 *
 * Returns the seeded Federal Decree-Law No.9/2024 signal shape.
 * No live MOHRE API — mock/seeded data only per CR-M scope decision
 * (seeded labor-law signal, no live MOHRE feed).
 *
 * Registered in source-fetch.worker.ts buildAdapterForRow() under
 * source_id = 'mohre_labor', enabling on-demand pull via
 * POST /api/v1/admin/sources/:id/pull.
 *
 * Math.random() is used in the seed jitter for non-security, decorative
 * variance only — acceptable per B15 (non-security randomness).
 */
import {
  computeDedupHash,
  type AdapterHealthCheckResult,
  type NormalisedSignal,
  type RateLimitConfig,
  type RawSignal,
  type SourceAdapter,
} from './source-adapter';

interface MohreAdapterOptions {
  source_id: string;
  source_reliability?: number;
}

interface MohreDecreePayload {
  decreeRef: string;
  effectiveDate: string;
  fineMin: number;
  fineMax: number;
  emiratisationBand: string;
  bandTargets: Record<string, number>;
  title: string;
  summary: string;
  eventDate: string;
  url: string;
}

/** The seeded Decree-Law No.9/2024 record. */
const SEEDED_DECREE: MohreDecreePayload = {
  decreeRef: 'Federal Decree-Law No. 9 of 2024',
  effectiveDate: '2024-08-30',
  fineMin: 100000,
  fineMax: 1000000,
  emiratisationBand: '20-49',
  bandTargets: { end2024: 1, '2025': 2 },
  title: 'Federal Decree-Law No. 9 of 2024 — Labor Relations Amendments',
  summary:
    'Federal Decree-Law No. 9 of 2024 effective 2024-08-30. ' +
    'Fines AED 100,000–1,000,000 for non-compliance. ' +
    'MOHRE rulings carry court-equivalent force. ' +
    'Emiratisation expanded to the 20–49 headcount band: ' +
    '≥1 Emirati required by end-2024, 2 by 2025. ' +
    'Fake-Emiratisation carries criminal exposure under Federal Law No. 6/2022.',
  eventDate: '2024-08-30',
  url: 'https://mohre.gov.ae/en/laws-and-regulations/federal-laws/labor-relations-amendments-2024.aspx',
};

export class MohreLaborAdapter implements SourceAdapter {
  readonly source_id: string;
  readonly source_reliability: number;
  readonly refresh_seconds = 86400;
  readonly rate_limit: RateLimitConfig | null = null;

  constructor(opts: MohreAdapterOptions) {
    this.source_id = opts.source_id;
    this.source_reliability = opts.source_reliability ?? 1.0;
  }

  async *fetch(_since: Date): AsyncIterator<RawSignal> {
    // On-demand pull yields the single seeded decree record.
    // In a live integration this would query the MOHRE regulatory gazette API.
    const fetchedAt = new Date();
    yield {
      payload: SEEDED_DECREE as unknown as Record<string, unknown>,
      fetched_at: fetchedAt,
    };
  }

  normalise(raw: RawSignal): NormalisedSignal {
    const p = raw.payload as unknown as MohreDecreePayload;
    const title = p?.title ?? '(untitled MOHRE decree)';
    const eventDate = p?.eventDate ? new Date(p.eventDate) : undefined;

    return {
      source_id: this.source_id,
      source_reliability: this.source_reliability,
      fetched_at: raw.fetched_at,
      ...(eventDate !== undefined ? { event_date: eventDate } : {}),
      kind: 'regulatory',
      title,
      summary: p?.summary,
      geographies: [{ isoCountry: 'AE' }],
      affected_entities: [],
      severity: 'high',
      confidence: 1.0,
      url: p?.url,
      raw_payload: raw.payload,
      dedup_hash: computeDedupHash(this.source_id, eventDate, raw.fetched_at, title),
    };
  }

  async health_check(): Promise<AdapterHealthCheckResult> {
    // Seeded mock — always healthy (no external dependency).
    return { state: 'healthy' };
  }
}
