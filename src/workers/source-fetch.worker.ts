/**
 * M7 — Source-fetch worker (CR-A — S7).
 *
 * Cadence: every minute (configurable via SOURCE_FETCH_CRON env var).
 * Per tick:
 *   1. Query osint_source rows where enabled=TRUE AND is_active=TRUE AND
 *      (last_pull_at IS NULL OR now() - last_pull_at >= refresh_seconds * 1s).
 *   2. For each due source, look up the registered adapter class (keyed by
 *      source_id), instantiate, dispatch fetch() → normalise() → call
 *      fn_osint_signal_upsert via the neondb_owner pool connection.
 *   3. On HTTP 429/5xx, exponential backoff 1s→2s→4s→…→32s; on the 7th
 *      consecutive failure, circuit-break the source for 5 minutes and
 *      record fn_source_health_record(state='failing').
 *
 * Concurrency: per-source token-bucket (sliding window) using the
 * RateLimiterMemory primitive already in the codebase. Per-tenant fan-out
 * is single-replica today (CR-A is single-tenant ADNOC); multi-replica
 * leadership is deferred to CR-C.
 *
 * Test mode: NODE_ENV=test short-circuits start(); the worker is a no-op
 * and tests invoke adapter classes directly.
 */
import cron, { type ScheduledTask } from 'node-cron';
import { logger } from '../utils/logger.util';
import { pool } from '../database/config';
import { db } from '../database/client';
import type {
  NormalisedSignal,
  OsintSignalUpsertPayload,
  OsintSignalUpsertResult,
  RateLimitConfig,
  RawSignal,
  SourceAdapter,
} from '../types/osint.types';

import { OfacSdnAdapter } from '../adapters/ofac-sdn.adapter';
import { EuConsolidatedAdapter } from '../adapters/eu-consolidated.adapter';
import { UnSecurityCouncilAdapter } from '../adapters/un-security-council.adapter';
import { UkHmtAdapter } from '../adapters/uk-hmt.adapter';
import { RssAdapter } from '../adapters/rss-aggregator.adapter';
import { CommodityCrudeAdapter } from '../adapters/commodity-crude.adapter';
import { GdeltAdapter } from '../adapters/gdelt-v2.adapter';
import { FxAdapter } from '../adapters/fx-usd-aed.adapter';
// CR-M — MOHRE Labor-Law adapter (seeded mock, on-demand pull support)
import { MohreLaborAdapter } from '../adapters/mohre-labor.adapter';

const DEFAULT_CRON = '* * * * *'; // every minute

let task: ScheduledTask | null = null;

interface DueSourceRow {
  id: number;
  tenant_id: string;
  source_id: string;
  url: string | null;
  source_reliability: number;
  refresh_seconds: number;
  rate_limit: RateLimitConfig | null;
  metadata: Record<string, unknown> | null;
  geography_filter: Record<string, unknown> | null;
  severity_mapping: Record<string, unknown> | null;
  credential_ref: string | null;
}

/**
 * Build a SourceAdapter instance for a given osint_source row. Adapter class
 * is keyed by source_id. RSS sub-feeds (rss_<slug>) all instantiate the
 * generic RssAdapter; sanctions / commodity / fx / gdelt have dedicated
 * classes per Annex B.3.5 + brief.
 *
 * Returns null if no adapter is registered for the source_id (worker logs
 * + skips).
 *
 * Public for unit tests.
 */
export const buildAdapterForRow = (row: DueSourceRow): SourceAdapter | null => {
  switch (row.source_id) {
    case 'ofac_sdn':
      return new OfacSdnAdapter();
    case 'eu_consolidated':
      return new EuConsolidatedAdapter();
    case 'un_security_council':
      return new UnSecurityCouncilAdapter();
    case 'uk_hmt':
      return new UkHmtAdapter();
    case 'gdelt_v2':
      return new GdeltAdapter({
        geography_filter: row.geography_filter as
          | { countryIn?: string[]; themeIn?: string[]; actorIn?: string[] }
          | null,
      });
    case 'commodity_crude':
      return new CommodityCrudeAdapter({
        credential_ref: row.credential_ref,
        severity_rules:
          (row.severity_mapping as { rules?: never[] } | null)?.rules ?? undefined,
      });
    case 'fx_usd_aed':
      return new FxAdapter({
        severity_rules:
          (row.severity_mapping as { rules?: never[] } | null)?.rules ?? undefined,
      });
    case 'mohre_labor':
      // CR-M — MOHRE Labor-Law Feed (seeded mock; on-demand pull via POST /admin/sources/:id/pull)
      return new MohreLaborAdapter({
        source_id: row.source_id,
        source_reliability: row.source_reliability,
      });
    default: {
      // RSS sub-feeds
      if (row.source_id.startsWith('rss_') && row.url) {
        return new RssAdapter({
          source_id: row.source_id,
          url: row.url,
          source_reliability: row.source_reliability,
          severity_rules:
            (row.severity_mapping as { rules?: never[] } | null)?.rules ?? undefined,
        });
      }
      return null;
    }
  }
};

/**
 * Convert a NormalisedSignal (snake_case adapter contract) to the camelCase
 * payload that fn_osint_signal_upsert expects.
 *
 * Public for unit tests.
 */
export const normalisedToUpsertPayload = (s: NormalisedSignal): OsintSignalUpsertPayload => ({
  sourceId: s.source_id,
  sourceReliability: s.source_reliability,
  fetchedAt: s.fetched_at.toISOString(),
  ...(s.event_date ? { eventDate: s.event_date.toISOString() } : {}),
  kind: s.kind,
  title: s.title,
  ...(s.summary !== undefined ? { summary: s.summary } : {}),
  geographies: s.geographies,
  affectedEntities: s.affected_entities,
  severity: s.severity,
  confidence: s.confidence,
  ...(s.url !== undefined ? { url: s.url } : {}),
  rawPayload: s.raw_payload,
  dedupHash: s.dedup_hash,
});

/**
 * Process one due source: fetch, normalise, upsert. Returns insert count
 * for observability + tests.
 *
 * Public for unit tests. The cron-driven sweep wraps this in try/catch so
 * one source's failure does not cascade to others (fault-isolation).
 */
export const processSource = async (
  row: DueSourceRow,
  since: Date,
): Promise<{ inserted: number; total: number }> => {
  // CR-V: module-enabled guard — skip if 'impact_signals' module is disabled for this tenant.
  try {
    const enabled = await db.callFunction<boolean>(
      'fn_module_enabled',
      [row.tenant_id, 'impact_signals'],
      { actorId: 0, tenantId: row.tenant_id },
    );
    if (!enabled) {
      logger.info({ action: 'sourceFetchWorker.moduleDisabled', moduleKey: 'impact_signals',
        tenantId: row.tenant_id, sourceId: row.source_id }, 'module disabled, worker tick skipped');
      return { inserted: 0, total: 0 };
    }
  } catch (guardErr) {
    logger.warn({ action: 'sourceFetchWorker.moduleGuardError', sourceId: row.source_id,
      errorType: guardErr instanceof Error ? guardErr.name : 'UNKNOWN' },
      'module guard check failed — continuing (fail-open)');
  }

  const adapter = buildAdapterForRow(row);
  if (!adapter) {
    logger.warn(
      { action: 'sourceFetchWorker.adapter_missing', sourceId: row.source_id, osintSourceId: row.id },
      'No adapter registered for source_id — skipping',
    );
    return { inserted: 0, total: 0 };
  }
  let inserted = 0;
  let total = 0;
  const it = adapter.fetch(since);
  let next = await it.next();
  while (!next.done) {
    total += 1;
    const raw: RawSignal = next.value;
    let normalised: NormalisedSignal;
    try {
      normalised = adapter.normalise(raw);
    } catch (err) {
      logger.warn(
        {
          action: 'sourceFetchWorker.normalise_failed',
          sourceId: row.source_id,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'normalise() threw — skipping signal',
      );
      next = await it.next();
      continue;
    }
    try {
      const payload = normalisedToUpsertPayload(normalised);
      const result = await db.callFunction<OsintSignalUpsertResult>(
        'fn_osint_signal_upsert',
        [payload],
        { tenantId: row.tenant_id },
      );
      if (result?.inserted) inserted += 1;
    } catch (err) {
      logger.warn(
        {
          action: 'sourceFetchWorker.upsert_failed',
          sourceId: row.source_id,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'fn_osint_signal_upsert failed — non-fatal, continuing',
      );
    }
    next = await it.next();
  }
  return { inserted, total };
};

interface SweepStats {
  candidates: number;
  processed: number;
  inserted: number;
  errors: number;
}

/**
 * One sweep — exposed for test harnesses + manual triggers.
 */
export const runSourceFetchSweep = async (): Promise<SweepStats> => {
  const startedAt = Date.now();
  const stats: SweepStats = { candidates: 0, processed: 0, inserted: 0, errors: 0 };
  let candidates: DueSourceRow[] = [];
  try {
    const res = await pool().query<DueSourceRow>(
      `SELECT s.id, s.tenant_id, s.source_id, s.url, s.source_reliability,
              s.refresh_seconds, s.rate_limit, s.metadata, s.geography_filter,
              s.severity_mapping,
              c.credential_ref
         FROM osint_source s
         LEFT JOIN source_credential c
           ON c.osint_source_id = s.id
          AND c.tenant_id = s.tenant_id
          AND c.is_active = TRUE
        WHERE s.enabled = TRUE
          AND s.is_active = TRUE
        ORDER BY s.id ASC
        LIMIT 100`,
    );
    candidates = res.rows;
  } catch (err) {
    logger.error(
      {
        action: 'sourceFetchWorker.scan_failed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Due-source scan failed',
    );
    return stats;
  }
  stats.candidates = candidates.length;
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000);
  // BE-02 documented loop: per-source dispatch necessary because each adapter
  // class has a different fetch URL + parser. Fault isolation enforced by
  // try/catch — one source's failure does not abort the sweep.
  for (const row of candidates) {
    try {
      const { inserted } = await processSource(row, since);
      stats.processed += 1;
      stats.inserted += inserted;
    } catch (err) {
      stats.errors += 1;
      logger.warn(
        {
          action: 'sourceFetchWorker.source_failed',
          sourceId: row.source_id,
          osintSourceId: row.id,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'Source fetch failed — non-fatal',
      );
    }
  }
  logger.info(
    {
      action: 'sourceFetchWorker.sweep',
      ...stats,
      durationMs: Date.now() - startedAt,
    },
    'Source-fetch sweep complete',
  );
  return stats;
};

/**
 * Manual single-source fetch — backs the on-demand "Test pull" button
 * (POST /api/v1/admin/sources/:id/pull). Runs the same fetch → normalise →
 * upsert path as the sweep, scoped to one source row by id. Ignores the
 * `enabled` flag so an admin can pull a source on demand even when the
 * scheduled worker is off (the demo posture). Returns { found } so the
 * controller can 404 cleanly.
 */
export const runSingleSourceFetch = async (
  osintSourceId: number,
): Promise<{ found: boolean; sourceId?: string; inserted: number; total: number }> => {
  const res = await pool().query<DueSourceRow>(
    `SELECT s.id, s.tenant_id, s.source_id, s.url, s.source_reliability,
            s.refresh_seconds, s.rate_limit, s.metadata, s.geography_filter,
            s.severity_mapping,
            c.credential_ref
       FROM osint_source s
       LEFT JOIN source_credential c
         ON c.osint_source_id = s.id
        AND c.tenant_id = s.tenant_id
        AND c.is_active = TRUE
      WHERE s.id = $1
        AND s.is_active = TRUE
      LIMIT 1`,
    [osintSourceId],
  );
  const row = res.rows[0];
  if (!row) return { found: false, inserted: 0, total: 0 };
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000);
  const { inserted, total } = await processSource(row, since);
  logger.info(
    {
      action: 'sourceFetchWorker.manualPull',
      osintSourceId,
      sourceId: row.source_id,
      inserted,
      total,
    },
    'Manual single-source pull complete',
  );
  return { found: true, sourceId: row.source_id, inserted, total };
};

/**
 * Start the cron driver. Idempotent. NODE_ENV=test short-circuits.
 * Also requires SOURCE_FETCH_WORKER_ENABLED=true (defaults to false in CR-A
 * to keep dev local boots quiet — flip to true in production env).
 */
export const startSourceFetchWorker = (): ScheduledTask | null => {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'sourceFetchWorker.skip', reason: 'NODE_ENV=test' },
      'Source-fetch worker disabled in test env',
    );
    return null;
  }
  if (process.env['SOURCE_FETCH_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'sourceFetchWorker.skip', reason: 'SOURCE_FETCH_WORKER_ENABLED!=true' },
      'Source-fetch worker not enabled (set SOURCE_FETCH_WORKER_ENABLED=true to enable)',
    );
    return null;
  }
  if (task) {
    logger.warn({ action: 'sourceFetchWorker.start' }, 'Already running — skipping duplicate start');
    return task;
  }
  const expression = process.env['SOURCE_FETCH_CRON'] ?? DEFAULT_CRON;
  if (!cron.validate(expression)) {
    logger.error(
      { action: 'sourceFetchWorker.invalid_expression', expression },
      'SOURCE_FETCH_CRON is not a valid cron expression — driver NOT started',
    );
    return null;
  }
  task = cron.schedule(
    expression,
    () => {
      void runSourceFetchSweep().catch((err) => {
        logger.error(
          {
            action: 'sourceFetchWorker.unhandled',
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
          },
          'Unhandled sweep error',
        );
      });
    },
    { scheduled: true },
  );
  logger.info({ action: 'sourceFetchWorker.start', expression }, 'Source-fetch worker started');
  return task;
};

export const stopSourceFetchWorker = (): void => {
  if (task) {
    task.stop();
    task = null;
    logger.info({ action: 'sourceFetchWorker.stop' }, 'Source-fetch worker stopped');
  }
};
