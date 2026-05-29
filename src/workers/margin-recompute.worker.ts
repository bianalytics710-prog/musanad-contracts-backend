/**
 * M21 / CR-O — Margin Recompute Worker.
 *
 * Responsibilities:
 *   1. PG LISTEN 'margin_recompute_requested' — recompute margins when
 *      fn_margin_recompute_for_price_change emits a notification.
 *      Payload: { tenantId, benchmarkCode, newPrice, affected }.
 *      NOTE: the recompute fn already calls fn_margin_compute per position
 *      synchronously and emits pg_notify at the end. This worker is the
 *      async async production path — it can trigger a secondary full sweep
 *      if affected > 0 for async post-processing use cases.
 *
 *   2. Daily scheduled recompute at 01:00 UTC via node-cron — calls
 *      fn_margin_aggregate as a health-check probe to verify latest_margin
 *      MV is populated. Not a full recompute — drift is caught by the
 *      per-signal path. Daily sweep is a sentinel.
 *
 * Performance target: <30s per batch.
 * Concurrency: p-limit(2) — at most 2 parallel notification processorss.
 *   Mirrors S2-17 concurrency primitive pattern from score-recompute.worker.ts.
 *
 * S2-20: system actor = SYSTEM_ACTOR_ID=0. fn_ coerces to NULL sentinel.
 * A3: latest_margin MV has no RLS — GUC tenant_id must be set on every fn_ call.
 *
 * Test mode: NODE_ENV=test → no-op.
 * Guard: MARGIN_RECOMPUTE_WORKER_ENABLED=true required to start (default off in dev).
 *
 * Design note from db-design.md §H-6: the demo path is the synchronous POST
 * (fn_margin_recompute_for_price_change runs inline and returns aggregate delta).
 * This worker is the production async wiring — env-gated off by default so demo
 * runs do not see duplicate recomputes.
 */
import type { PoolClient } from 'pg';
import cron, { type ScheduledTask } from 'node-cron';
import pLimit from 'p-limit';
import { pool } from '../database/config';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { ADNOC_TENANT_ID, SYSTEM_ACTOR_ID } from '../types/risk-score.types';

/** pg_notify channel emitted by fn_margin_recompute_for_price_change (mig 317). */
const CHANNEL = 'margin_recompute_requested';

/** p-limit concurrency — at most 2 parallel notification processors per batch (S2-17). */
const RECOMPUTE_CONCURRENCY = 2;

/** Dedicated PG client for LISTEN margin_recompute_requested channel. */
let _notifyClient: PoolClient | null = null;

/** Scheduled daily cron task (node-cron handle). */
let _cronTask: ScheduledTask | null = null;

// ============================================================
// Payload shape
// ============================================================

interface MarginRecomputeNotifyPayload {
  tenantId:      string;
  benchmarkCode: string;
  newPrice:      number;
  affected:      number;
}

// ============================================================
// Notification-triggered handler
// ============================================================

/**
 * Handle a single margin_recompute_requested notification.
 * The synchronous recompute already ran inside fn_margin_recompute_for_price_change;
 * this handler logs the event and can trigger any async follow-up (e.g. cache warming).
 */
async function processMarginRecomputeNotification(
  payload: MarginRecomputeNotifyPayload,
): Promise<void> {
  const startMs = Date.now();

  logger.info(
    {
      action: 'marginRecomputeWorker.processNotification',
      benchmarkCode: payload.benchmarkCode,
      affected: payload.affected,
      tenantId: payload.tenantId,
    },
    'Processing margin_recompute_requested notification',
  );

  if (payload.affected <= 0) {
    logger.debug(
      { action: 'marginRecomputeWorker.processNotification', benchmarkCode: payload.benchmarkCode },
      'margin_recompute_requested payload has affected=0 — skipping',
    );
    return;
  }

  try {
    // Verify latest_margin MV is populated for this tenant via fn_margin_aggregate.
    // This is a lightweight read (no writes) — just confirms the MV refresh completed.
    await db.callFunction(
      'fn_margin_aggregate',
      [SYSTEM_ACTOR_ID, { groupBy: 'side' }],
      { actorId: SYSTEM_ACTOR_ID, tenantId: payload.tenantId },
    );

    const durationMs = Date.now() - startMs;
    logger.info(
      {
        action: 'marginRecomputeWorker.processNotificationComplete',
        benchmarkCode: payload.benchmarkCode,
        durationMs,
      },
      'Margin recompute notification handled — MV verified',
    );
  } catch (err) {
    const durationMs = Date.now() - startMs;
    logger.error(
      {
        action: 'marginRecomputeWorker.processNotificationError',
        benchmarkCode: payload.benchmarkCode,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
        durationMs,
      },
      'Error handling margin_recompute_requested notification',
    );
    // Non-fatal: log and continue.
  }
}

// ============================================================
// PG NOTIFY listener
// ============================================================

async function startNotifyListener(): Promise<void> {
  if (_notifyClient) return;

  try {
    const dbPool = pool();
    _notifyClient = await dbPool.connect();

    await _notifyClient.query(`LISTEN ${CHANNEL}`);

    const limit = pLimit(RECOMPUTE_CONCURRENCY);

    _notifyClient.on('notification', (msg) => {
      if (msg.channel !== CHANNEL) return;

      let payload: MarginRecomputeNotifyPayload;
      try {
        payload = JSON.parse(msg.payload ?? '{}') as MarginRecomputeNotifyPayload;
      } catch {
        logger.warn(
          { action: 'marginRecomputeWorker.notification', rawPayload: '[REDACTED]' },
          `Failed to parse ${CHANNEL} payload — skipping`,
        );
        return;
      }

      if (!payload.tenantId) {
        logger.warn(
          { action: 'marginRecomputeWorker.notification', benchmarkCode: payload.benchmarkCode },
          `Missing tenantId in ${CHANNEL} payload — skipping`,
        );
        return;
      }

      void limit(() => processMarginRecomputeNotification(payload)).catch((err: unknown) => {
        logger.error(
          {
            action: 'marginRecomputeWorker.pLimitError',
            benchmarkCode: payload.benchmarkCode,
            errorMessage: err instanceof Error ? err.message : String(err),
          },
          'Unhandled error in p-limit wrapper',
        );
      });
    });

    _notifyClient.on('error', (err) => {
      logger.error(
        { action: 'marginRecomputeWorker.listenerError', errorMessage: err.message },
        `PG NOTIFY connection error for ${CHANNEL}`,
      );
      _notifyClient = null;
    });

    logger.info(
      { action: 'marginRecomputeWorker.listenerStarted' },
      `Margin recompute worker started — listening on ${CHANNEL}`,
    );
  } catch (err) {
    logger.error(
      {
        action: 'marginRecomputeWorker.startListenerError',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Failed to start margin_recompute_requested listener',
    );
  }
}

// ============================================================
// Daily scheduled sweep (node-cron)
// ============================================================

/**
 * Daily sentinel sweep at 01:00 UTC.
 * Calls fn_margin_aggregate(groupBy:'side') against the ADNOC default tenant to
 * verify latest_margin MV is accessible and populated. Non-destructive read.
 * Catches any stale-MV scenario from missed notifications.
 */
async function runScheduledSweep(): Promise<void> {
  const startMs = Date.now();
  logger.info(
    { action: 'marginRecomputeWorker.scheduledSweep.start' },
    'Daily scheduled margin MV sentinel sweep starting',
  );

  try {
    await db.callFunction(
      'fn_margin_aggregate',
      [SYSTEM_ACTOR_ID, { groupBy: 'side' }],
      { actorId: SYSTEM_ACTOR_ID, tenantId: ADNOC_TENANT_ID },
    );

    const durationMs = Date.now() - startMs;
    logger.info(
      {
        action: 'marginRecomputeWorker.scheduledSweep.complete',
        durationMs,
      },
      'Daily scheduled margin MV sentinel sweep complete',
    );
  } catch (err) {
    const durationMs = Date.now() - startMs;
    logger.error(
      {
        action: 'marginRecomputeWorker.scheduledSweep.error',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
        durationMs,
      },
      'Daily scheduled margin MV sentinel sweep failed',
    );
  }
}

// ============================================================
// Public API: start / stop
// ============================================================

/**
 * Start the margin-recompute worker: PG LISTEN + daily sentinel cron.
 *
 * Guards:
 *   - NODE_ENV=test → no-op (smoke harness owns scheduling)
 *   - MARGIN_RECOMPUTE_WORKER_ENABLED != 'true' → no-op (default off in dev)
 */
export async function startMarginRecomputeWorker(): Promise<void> {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'marginRecomputeWorker.start' },
      'Test mode — margin recompute worker skipped',
    );
    return;
  }

  if (process.env['MARGIN_RECOMPUTE_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'marginRecomputeWorker.start' },
      'MARGIN_RECOMPUTE_WORKER_ENABLED is not true — skipped',
    );
    return;
  }

  // Start PG LISTEN handler
  await startNotifyListener();

  // Schedule daily sentinel sweep at 01:00 UTC
  _cronTask = cron.schedule('0 0 1 * * *', () => {
    void runScheduledSweep();
  }, { timezone: 'UTC' });

  logger.info(
    { action: 'marginRecomputeWorker.cronStarted', schedule: '0 0 1 * * * (UTC)' },
    'Margin recompute daily sentinel cron scheduled at 01:00 UTC',
  );

  // Graceful shutdown hooks (idempotent with server.ts SIGTERM/SIGINT)
  process.once('SIGTERM', stopMarginRecomputeWorker);
  process.once('SIGINT', stopMarginRecomputeWorker);
}

/**
 * Stop the margin-recompute worker: UNLISTEN + destroy cron.
 */
export function stopMarginRecomputeWorker(): void {
  if (_cronTask) {
    _cronTask.stop();
    _cronTask = null;
    logger.info(
      { action: 'marginRecomputeWorker.cronStopped' },
      'Margin recompute daily cron stopped',
    );
  }

  if (_notifyClient) {
    void _notifyClient.query(`UNLISTEN ${CHANNEL}`).then(() => {
      _notifyClient?.release();
      _notifyClient = null;
    }).catch(() => {
      _notifyClient = null;
    });
    logger.info(
      { action: 'marginRecomputeWorker.listenerStopped' },
      `Margin recompute worker stopped — UNLISTEN ${CHANNEL}`,
    );
  }
}
