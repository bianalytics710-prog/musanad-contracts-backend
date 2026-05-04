/**
 * M4 / S8 — ai_insight cache eviction cron driver.
 *
 * Calls fn_ai_insight_evict_expired(p_batch_size) in a loop until the
 * returned `evictedCount` is less than the batch size. The fn is
 * SECURITY DEFINER + GRANT EXECUTE TO neondb_owner ONLY (REVOKED FROM PUBLIC).
 *
 * S2-20 SYSTEM_ACTOR sentinel: this driver MUST set
 * `app.current_user_id = '0'` before invoking the fn so audit_log records
 * cron-driven soft-deactivates with the system-actor coercion. Mirrors M2
 * approval-escalation + M3 signature-expiration cron drivers.
 *
 * Default schedule: every 15 minutes. Override via
 * AI_INSIGHT_EVICTION_INTERVAL_CRON env var. Disabled in NODE_ENV=test.
 *
 * Mirrors:
 *   - src/services/approval-escalation.cron.service.ts (M2 / S9)
 *   - src/services/signature-expiration.cron.service.ts (M3 / S9)
 *
 * This is the THIRD cron driver in the codebase. DN-5 of M4 db-design.md
 * notes the 3-instance threshold as a candidate generalization point —
 * deferred to a future infra-module decision.
 */
import cron, { type ScheduledTask } from 'node-cron';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import type { AiInsightEvictExpiredResult } from '../types/ai.types';

const DEFAULT_CRON = '*/15 * * * *';
const BATCH_SIZE = 500;
/** Fail-safe: never let one sweep loop more than this many batches. */
const MAX_BATCHES_PER_SWEEP = 50;

/**
 * S2-20 sentinel — fn_audit_trigger reads app.current_user_id but does not
 * coerce 0→NULL (M0 baseline behavior). Cron driver still uses 0 to mark
 * the row as system-driven; the audit trail downstream consumer interprets
 * actor=0 as the system actor. Mirrors M2/M3 cron precedent.
 */
const SYSTEM_ACTOR_ID = 0;

let task: ScheduledTask | null = null;

interface SweepStats {
  batches: number;
  totalEvicted: number;
  durationMs: number;
}

/**
 * One eviction sweep. Loops until the fn_ returns fewer evictions than
 * BATCH_SIZE (drained) OR MAX_BATCHES_PER_SWEEP is reached (safety cap).
 *
 * Exposed for tests + startup self-test.
 */
export const runEvictionSweep = async (): Promise<SweepStats> => {
  const startTime = Date.now();
  let batches = 0;
  let totalEvicted = 0;

  for (;;) {
    if (batches >= MAX_BATCHES_PER_SWEEP) {
      logger.warn(
        {
          action: 'aiInsightEvictionCron.batch_cap_reached',
          batches,
          totalEvicted,
        },
        'Hit MAX_BATCHES_PER_SWEEP — leaving remaining evictions for the next sweep',
      );
      break;
    }
    let result: AiInsightEvictExpiredResult | null;
    try {
      const raw = await db.callFunction<{ data?: AiInsightEvictExpiredResult } | AiInsightEvictExpiredResult>(
        'fn_ai_insight_evict_expired',
        [BATCH_SIZE],
        { actorId: SYSTEM_ACTOR_ID },
      );
      // fn_ wraps the body in { data: { evictedCount } } per design Section
      // 2.2 spec; tolerate either shape defensively.
      if (raw === null || raw === undefined) {
        result = null;
      } else if ('evictedCount' in (raw as object)) {
        result = raw as AiInsightEvictExpiredResult;
      } else if (
        'data' in (raw as object) &&
        (raw as { data?: AiInsightEvictExpiredResult }).data
      ) {
        result = (raw as { data: AiInsightEvictExpiredResult }).data;
      } else {
        result = null;
      }
    } catch (err) {
      logger.error(
        {
          action: 'aiInsightEvictionCron.batch_failed',
          batchIndex: batches,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
          message: err instanceof Error ? err.message : String(err),
        },
        'AI insight eviction batch failed (non-fatal)',
      );
      // Per memory feedback_db_impl_report_dont_fix.md: do not silently
      // swallow. Log and break out so operator visibility is preserved;
      // the next cron tick retries.
      break;
    }

    if (!result) {
      // fn returned NULL — treat as drained.
      break;
    }

    batches += 1;
    totalEvicted += Number(result.evictedCount ?? 0);

    if (Number(result.evictedCount ?? 0) < BATCH_SIZE) {
      // Drained — no more rows due for eviction in this window.
      break;
    }
  }

  const stats: SweepStats = {
    batches,
    totalEvicted,
    durationMs: Date.now() - startTime,
  };

  if (totalEvicted === 0) {
    logger.debug(
      { action: 'aiInsightEvictionCron.sweep', ...stats },
      'No expired ai_insight rows due for eviction',
    );
  } else {
    logger.info(
      { action: 'aiInsightEvictionCron.sweep', ...stats },
      'AI insight eviction sweep complete',
    );
  }

  return stats;
};

/** Start the cron driver. Idempotent. NODE_ENV=test short-circuits. */
export const startAiInsightEvictionCron = (): ScheduledTask | null => {
  if (process.env.NODE_ENV === 'test') {
    logger.info(
      { action: 'aiInsightEvictionCron.skip', reason: 'NODE_ENV=test' },
      'AI insight eviction cron disabled in test env',
    );
    return null;
  }
  if (task) {
    logger.warn(
      { action: 'aiInsightEvictionCron.start' },
      'AI insight eviction cron already running — skipping duplicate start',
    );
    return task;
  }
  const expression = process.env.AI_INSIGHT_EVICTION_INTERVAL_CRON ?? DEFAULT_CRON;
  if (!cron.validate(expression)) {
    logger.error(
      { action: 'aiInsightEvictionCron.invalid_expression', expression },
      'AI_INSIGHT_EVICTION_INTERVAL_CRON is not a valid cron expression — driver NOT started',
    );
    return null;
  }
  task = cron.schedule(
    expression,
    () => {
      void runEvictionSweep().catch((err) => {
        logger.error(
          {
            action: 'aiInsightEvictionCron.unhandled',
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
            message: err instanceof Error ? err.message : String(err),
          },
          'Unhandled AI insight eviction sweep error',
        );
      });
    },
    { scheduled: true },
  );
  logger.info(
    { action: 'aiInsightEvictionCron.start', expression },
    'AI insight eviction cron started',
  );
  return task;
};

/** Stop the cron driver. Used by graceful shutdown + tests. */
export const stopAiInsightEvictionCron = (): void => {
  if (task) {
    task.stop();
    task = null;
    logger.info(
      { action: 'aiInsightEvictionCron.stop' },
      'AI insight eviction cron stopped',
    );
  }
};
