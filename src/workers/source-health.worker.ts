/**
 * M7 — Source-health worker (CR-A — S8).
 *
 * Cadence: every 5 minutes (Q4 lock — Annex B.7.1 default). Configurable
 * via SOURCE_HEALTH_CRON.
 *
 * Per tick:
 *   1. Query enabled + active osint_source rows.
 *   2. For each source, instantiate the adapter, call adapter.health_check().
 *   3. Compute signals_24h = SELECT COUNT(*) FROM osint_signal
 *        WHERE osint_source_id = $1 AND fetched_at >= now() - interval '24h'.
 *   4. Persist via fn_source_health_record (DEFINER cron-only, neondb_owner).
 *
 * Test mode: NODE_ENV=test → no-op. Requires SOURCE_HEALTH_WORKER_ENABLED=true
 * (mirror SOURCE_FETCH_WORKER_ENABLED gating).
 */
import cron, { type ScheduledTask } from 'node-cron';
import { logger } from '../utils/logger.util';
import { pool } from '../database/config';
import { db } from '../database/client';
import { buildAdapterForRow } from './source-fetch.worker';
import type { RateLimitConfig, SourceHealthRecordResult } from '../types/osint.types';

const DEFAULT_CRON = '*/5 * * * *'; // every 5 minutes

let task: ScheduledTask | null = null;

interface HealthCheckRow {
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

interface SweepStats {
  candidates: number;
  processed: number;
  failed: number;
}

const countSignals24h = async (osintSourceId: number, tenantId: string): Promise<number> => {
  try {
    const r = await pool().query<{ c: string }>(
      `SELECT COUNT(*)::text AS c
         FROM osint_signal
        WHERE osint_source_id = $1
          AND tenant_id       = $2::uuid
          AND fetched_at      >= now() - interval '24 hours'`,
      [osintSourceId, tenantId],
    );
    const raw = r.rows[0]?.c ?? '0';
    const n = Number(raw);
    return Number.isFinite(n) ? n : 0;
  } catch (err) {
    logger.warn(
      {
        action: 'sourceHealthWorker.signals_24h_failed',
        osintSourceId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'signals_24h count failed — defaulting to 0',
    );
    return 0;
  }
};

/**
 * Run one health-check for a single source row. Public for unit tests.
 */
export const runHealthCheckForSource = async (row: HealthCheckRow): Promise<void> => {
  // CR-V: module-enabled guard — skip if 'impact_signals' module is disabled for this tenant.
  try {
    const enabled = await db.callFunction<boolean>(
      'fn_module_enabled',
      [row.tenant_id, 'impact_signals'],
      { actorId: 0, tenantId: row.tenant_id },
    );
    if (!enabled) {
      logger.info({ action: 'sourceHealthWorker.moduleDisabled', moduleKey: 'impact_signals',
        tenantId: row.tenant_id, sourceId: row.source_id }, 'module disabled, worker tick skipped');
      return;
    }
  } catch (guardErr) {
    logger.warn({ action: 'sourceHealthWorker.moduleGuardError', sourceId: row.source_id,
      errorType: guardErr instanceof Error ? guardErr.name : 'UNKNOWN' },
      'module guard check failed — continuing (fail-open)');
  }

  // buildAdapterForRow accepts the full DueSourceRow shape from the fetch
  // worker; signature compatible — both rows carry the same columns.
  const adapter = buildAdapterForRow(row);
  if (!adapter) {
    logger.warn(
      { action: 'sourceHealthWorker.adapter_missing', sourceId: row.source_id },
      'No adapter — skipping health check',
    );
    return;
  }
  let state: 'healthy' | 'degraded' | 'failing' | 'unauthorised' = 'healthy';
  let errorMsg: string | undefined;
  try {
    const result = await adapter.health_check();
    state = result.state;
    if (result.error) errorMsg = result.error;
  } catch (err) {
    state = 'failing';
    errorMsg = err instanceof Error ? err.message : String(err);
  }
  const signals24h = await countSignals24h(row.id, row.tenant_id);
  try {
    await db.callFunction<SourceHealthRecordResult>(
      'fn_source_health_record',
      [row.id, state, errorMsg ?? null, signals24h],
      { tenantId: row.tenant_id },
    );
  } catch (err) {
    logger.warn(
      {
        action: 'sourceHealthWorker.record_failed',
        sourceId: row.source_id,
        state,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_source_health_record failed — non-fatal',
    );
  }
};

export const runSourceHealthSweep = async (): Promise<SweepStats> => {
  const startedAt = Date.now();
  const stats: SweepStats = { candidates: 0, processed: 0, failed: 0 };
  let candidates: HealthCheckRow[] = [];
  try {
    const res = await pool().query<HealthCheckRow>(
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
        action: 'sourceHealthWorker.scan_failed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Health-check candidate scan failed',
    );
    return stats;
  }
  stats.candidates = candidates.length;
  // BE-02 — per-source dispatch loop documented inline.
  for (const row of candidates) {
    try {
      await runHealthCheckForSource(row);
      stats.processed += 1;
    } catch (err) {
      stats.failed += 1;
      logger.warn(
        {
          action: 'sourceHealthWorker.source_failed',
          sourceId: row.source_id,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'Source health check failed — non-fatal',
      );
    }
  }
  logger.info(
    {
      action: 'sourceHealthWorker.sweep',
      ...stats,
      durationMs: Date.now() - startedAt,
    },
    'Source-health sweep complete',
  );
  return stats;
};

export const startSourceHealthWorker = (): ScheduledTask | null => {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'sourceHealthWorker.skip', reason: 'NODE_ENV=test' },
      'Source-health worker disabled in test env',
    );
    return null;
  }
  if (process.env['SOURCE_HEALTH_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'sourceHealthWorker.skip', reason: 'SOURCE_HEALTH_WORKER_ENABLED!=true' },
      'Source-health worker not enabled (set SOURCE_HEALTH_WORKER_ENABLED=true to enable)',
    );
    return null;
  }
  if (task) {
    logger.warn(
      { action: 'sourceHealthWorker.start' },
      'Already running — skipping duplicate start',
    );
    return task;
  }
  const expression = process.env['SOURCE_HEALTH_CRON'] ?? DEFAULT_CRON;
  if (!cron.validate(expression)) {
    logger.error(
      { action: 'sourceHealthWorker.invalid_expression', expression },
      'SOURCE_HEALTH_CRON is not a valid cron expression — driver NOT started',
    );
    return null;
  }
  task = cron.schedule(
    expression,
    () => {
      void runSourceHealthSweep().catch((err) => {
        logger.error(
          {
            action: 'sourceHealthWorker.unhandled',
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
          },
          'Unhandled sweep error',
        );
      });
    },
    { scheduled: true },
  );
  logger.info({ action: 'sourceHealthWorker.start', expression }, 'Source-health worker started');
  return task;
};

export const stopSourceHealthWorker = (): void => {
  if (task) {
    task.stop();
    task = null;
    logger.info({ action: 'sourceHealthWorker.stop' }, 'Source-health worker stopped');
  }
};
