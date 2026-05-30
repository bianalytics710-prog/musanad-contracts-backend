/**
 * M14 / CR-F — Score Recompute Worker.
 *
 * Responsibilities:
 *   1. PG LISTEN 'correlation_inserted' — recompute risk score when fn_rule_evaluate
 *      inserts new correlations. Calls fn_score_recompute_for_signal(signal_id, actor_id).
 *   2. Daily scheduled recompute at 00:30 UTC via node-cron — calls
 *      fn_score_recompute_for_weight_change(SYSTEM_ACTOR_ID) to catch drift.
 *
 * Performance target: <30s per affected contract.
 * Concurrency: p-limit(2) — at most 2 parallel signal recomputes per notification batch.
 *   Mirrors S2-17 concurrency primitive pattern from CR-D0 ingestion.worker.ts.
 *
 * S2-20: system actor = SYSTEM_ACTOR_ID=0. fn_risk_score_compute coerces to NULL sentinel.
 * S2-17: fn_risk_score_compute uses FOR UPDATE dedup 60s window to prevent duplicate inserts.
 * A3: latest_risk_score MV has no RLS — GUC tenant_id must be set on every fn_ call.
 *
 * Test mode: NODE_ENV=test → no-op.
 * Guard: SCORE_RECOMPUTE_WORKER_ENABLED=true required to start (default off in dev).
 *
 * QA Stage 3 W1 note: CorrelationInsertedNotifyPayload.signalId is a JSON number
 * (not string). In v1 signal IDs are well below 2^53 — acceptable-risk decision
 * documented in types/risk-score.types.ts.
 */
import type { PoolClient } from 'pg';
import cron, { type ScheduledTask } from 'node-cron';
import pLimit from 'p-limit';
import { pool } from '../database/config';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import type {
  CorrelationInsertedNotifyPayload,
  ScoreRecomputeForSignalResult,
  ScoreRecomputeForWeightChangeResult,
} from '../types/risk-score.types';
import { ADNOC_TENANT_ID, SYSTEM_ACTOR_ID } from '../types/risk-score.types';

/** p-limit concurrency — at most 2 parallel signal recomputes per batch (S2-17). */
const RECOMPUTE_CONCURRENCY = 2;

/** Dedicated PG client for LISTEN correlation_inserted channel. */
let _notifyClient: PoolClient | null = null;

/** Scheduled daily cron task (node-cron handle). */
let _cronTask: ScheduledTask | null = null;

// ============================================================
// Signal-triggered recompute
// ============================================================

/**
 * Process a single signal: call fn_score_recompute_for_signal(p_signal_id, p_actor_id).
 * fn_ handles: cross-correlation lookup for all contracts affected by this signal,
 * FOR UPDATE dedup window (60s), per-contract SAVEPOINT isolation.
 *
 * @param signalId - BIGINT signal ID from pg_notify payload.
 * @param tenantId - UUID tenant for GUC context (from notify payload).
 *
 * CR-V NOTE: score-recompute worker is intentionally NOT gated by any single module.
 * Risk scoring spans risk_cases, financial.trade_margin, financial.budget_burn, and
 * dashboards.* — no clean single-module mapping exists. Scoring runs regardless of
 * module enable state so that stale scores don't accumulate if individual ECIP modules
 * are toggled off and then back on. DEBT: consider a dedicated 'risk_scoring' module
 * key in a future CR if per-module scoring control is needed.
 */
async function processSignal(signalId: number, tenantId: string): Promise<void> {
  const startMs = Date.now();

  logger.info(
    { action: 'scoreRecomputeWorker.processSignal', signalId, tenantId },
    'Processing correlation_inserted signal for risk score recompute',
  );

  try {
    // DB signature: fn_score_recompute_for_signal(p_signal_id BIGINT, p_actor_id BIGINT) RETURNS JSONB
    // SYSTEM_ACTOR_ID=0 is the sentinel for automated worker recomputes (S2-20).
    const result = await db.callFunction<ScoreRecomputeForSignalResult>(
      'fn_score_recompute_for_signal',
      [signalId, SYSTEM_ACTOR_ID],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );

    const durationMs = Date.now() - startMs;
    logger.info(
      {
        action: 'scoreRecomputeWorker.processSignalComplete',
        signalId,
        affectedContractCount: result?.affectedContractCount ?? 0,
        deduplicatedContractCount: result?.deduplicatedContractCount ?? 0,
        durationMs,
      },
      'Signal risk score recompute complete',
    );

    // NFR: log if any single signal recompute exceeds 30s target
    if (durationMs > 30_000) {
      logger.warn(
        { action: 'scoreRecomputeWorker.slowRecompute', signalId, durationMs },
        'Signal recompute exceeded 30s NFR target',
      );
    }
  } catch (err) {
    const durationMs = Date.now() - startMs;
    logger.error(
      {
        action: 'scoreRecomputeWorker.processSignalError',
        signalId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
        durationMs,
      },
      'Error recomputing risk score for signal',
    );
    // Non-fatal: log and continue. The next correlation_inserted event will
    // re-trigger if the signal still has active correlations.
  }
}

// ============================================================
// PG NOTIFY listener
// ============================================================

/**
 * Start the PG LISTEN handler for 'correlation_inserted' channel.
 * fn_rule_evaluate (migration 172) emits this notification after inserting correlations.
 */
async function startNotifyListener(): Promise<void> {
  if (_notifyClient) return;

  try {
    const dbPool = pool();
    _notifyClient = await dbPool.connect();

    await _notifyClient.query('LISTEN correlation_inserted');

    const limit = pLimit(RECOMPUTE_CONCURRENCY);

    _notifyClient.on('notification', (msg) => {
      if (msg.channel !== 'correlation_inserted') return;

      let payload: CorrelationInsertedNotifyPayload;
      try {
        payload = JSON.parse(msg.payload ?? '{}') as CorrelationInsertedNotifyPayload;
      } catch {
        logger.warn(
          { action: 'scoreRecomputeWorker.notification', rawPayload: '[REDACTED]' },
          'Failed to parse correlation_inserted payload — skipping',
        );
        return;
      }

      const { signalId, tenantId, inserted } = payload;

      if (!signalId || signalId <= 0) {
        logger.warn(
          { action: 'scoreRecomputeWorker.notification', inserted },
          'Invalid signalId in correlation_inserted payload — skipping',
        );
        return;
      }

      if (!tenantId) {
        logger.warn(
          { action: 'scoreRecomputeWorker.notification', signalId },
          'Missing tenantId in correlation_inserted payload — skipping',
        );
        return;
      }

      if (inserted <= 0) {
        logger.debug(
          { action: 'scoreRecomputeWorker.notification', signalId, inserted },
          'correlation_inserted payload has inserted=0 — skipping (verify ping)',
        );
        return;
      }

      // Process asynchronously under p-limit concurrency. Don't block the
      // notification handler — fire and forget with error logging inside.
      void limit(() => processSignal(signalId, tenantId)).catch((err: unknown) => {
        logger.error(
          {
            action: 'scoreRecomputeWorker.pLimitError',
            signalId,
            errorMessage: err instanceof Error ? err.message : String(err),
          },
          'Unhandled error in p-limit wrapper',
        );
      });
    });

    _notifyClient.on('error', (err) => {
      logger.error(
        { action: 'scoreRecomputeWorker.listenerError', errorMessage: err.message },
        'PG NOTIFY connection error for correlation_inserted',
      );
      _notifyClient = null;
    });

    logger.info(
      { action: 'scoreRecomputeWorker.listenerStarted' },
      'Score recompute worker started — listening on correlation_inserted',
    );
  } catch (err) {
    logger.error(
      {
        action: 'scoreRecomputeWorker.startListenerError',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Failed to start correlation_inserted listener',
    );
  }
}

// ============================================================
// Daily scheduled recompute (node-cron)
// ============================================================

/**
 * Daily full recompute via fn_score_recompute_for_weight_change at 00:30 UTC.
 * Catches drift from weight changes and any missed signal events.
 * System actor = 0 (S2-20 sentinel — fn_ coerces to NULL for created_by).
 */
async function runScheduledRecompute(): Promise<void> {
  const startMs = Date.now();
  logger.info(
    { action: 'scoreRecomputeWorker.scheduledRecompute.start' },
    'Daily scheduled risk score recompute starting',
  );

  try {
    // DB signature: fn_score_recompute_for_weight_change(p_actor_id BIGINT) RETURNS JSONB
    const result = await db.callFunction<ScoreRecomputeForWeightChangeResult>(
      'fn_score_recompute_for_weight_change',
      [SYSTEM_ACTOR_ID],
      { actorId: SYSTEM_ACTOR_ID, tenantId: ADNOC_TENANT_ID },
    );

    const durationMs = Date.now() - startMs;
    logger.info(
      {
        action: 'scoreRecomputeWorker.scheduledRecompute.complete',
        weightsVersion: result?.weightsVersion,
        recomputedCount: result?.recomputedCount,
        failedCount: result?.failedContractIds?.length ?? 0,
        durationMs,
      },
      'Daily scheduled risk score recompute complete',
    );
  } catch (err) {
    const durationMs = Date.now() - startMs;
    logger.error(
      {
        action: 'scoreRecomputeWorker.scheduledRecompute.error',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
        durationMs,
      },
      'Daily scheduled risk score recompute failed',
    );
  }
}

// ============================================================
// Public API: start / stop
// ============================================================

/**
 * Start the score-recompute worker: PG LISTEN + daily cron.
 *
 * Guards:
 *   - NODE_ENV=test → no-op (smoke harness owns scheduling)
 *   - SCORE_RECOMPUTE_WORKER_ENABLED != 'true' → no-op (default off in dev)
 */
export async function startScoreRecomputeWorker(): Promise<void> {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'scoreRecomputeWorker.start' },
      'Test mode — score recompute worker skipped',
    );
    return;
  }

  if (process.env['SCORE_RECOMPUTE_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'scoreRecomputeWorker.start' },
      'SCORE_RECOMPUTE_WORKER_ENABLED is not true — skipped',
    );
    return;
  }

  // Start PG LISTEN handler
  await startNotifyListener();

  // Schedule daily recompute at 00:30 UTC
  // Cron format: second=0 minute=30 hour=0 day=* month=* weekday=*
  _cronTask = cron.schedule('0 30 0 * * *', () => {
    void runScheduledRecompute();
  }, { timezone: 'UTC' });

  logger.info(
    { action: 'scoreRecomputeWorker.cronStarted', schedule: '0 30 0 * * * (UTC)' },
    'Score recompute daily cron scheduled at 00:30 UTC',
  );

  // Graceful shutdown hooks (idempotent with server.ts SIGTERM/SIGINT)
  process.once('SIGTERM', stopScoreRecomputeWorker);
  process.once('SIGINT', stopScoreRecomputeWorker);
}

/**
 * Stop the score-recompute worker: UNLISTEN + destroy cron.
 */
export function stopScoreRecomputeWorker(): void {
  if (_cronTask) {
    _cronTask.stop();
    _cronTask = null;
    logger.info(
      { action: 'scoreRecomputeWorker.cronStopped' },
      'Score recompute daily cron stopped',
    );
  }

  if (_notifyClient) {
    void _notifyClient.query('UNLISTEN correlation_inserted').then(() => {
      _notifyClient?.release();
      _notifyClient = null;
    }).catch(() => {
      _notifyClient = null;
    });
    logger.info(
      { action: 'scoreRecomputeWorker.listenerStopped' },
      'Score recompute worker stopped — UNLISTEN correlation_inserted',
    );
  }
}
