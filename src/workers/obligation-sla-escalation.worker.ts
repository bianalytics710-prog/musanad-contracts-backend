/**
 * Obligation SLA Escalation Worker.
 *
 * Every day at 05:00 UTC (= 09:00 UAE) by default (override via
 * OBLIGATION_SLA_CRON). Calls the DEFINER fn_obligation_sla_check() to
 * enumerate {obligation_id, tier_day} pairs that have crossed an SLA
 * threshold and haven't yet been dispatched. For each candidate, sets the
 * per-row tenant GUC and calls fn_obligation_sla_dispatch which fans in-app
 * notifications to the type's owner roles + tier extras + assignee.
 *
 * Guards:
 *   - NODE_ENV=test → no-op
 *   - OBLIGATION_SLA_WORKER_ENABLED != 'true' → no-op (default OFF in dev)
 *
 * Idempotency: dispatch is guarded by both an in-fn EXISTS check AND a
 * UNIQUE INDEX on (obligation_id, tier_day) WHERE escalation_type='sla',
 * so a missed run or accidental double-fire never produces duplicate
 * notifications.
 *
 * Failure handling: each dispatch is wrapped in its own try/catch. A
 * failed candidate logs a WARN and the worker moves on; the next tick
 * will retry (the UNIQUE INDEX still prevents duplicates if the previous
 * attempt completed past the INSERT but before the notification fanout).
 */
import cron, { type ScheduledTask } from 'node-cron';
import pLimit from 'p-limit';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';

const SYSTEM_ACTOR_ID = 0;
const CONCURRENCY = 2;
const DEFAULT_LIMIT = 200;
// 05:00 UTC daily = 09:00 in UAE (UTC+4).
const DEFAULT_SCHEDULE_CRON = '0 5 * * *';

let _cronTask: ScheduledTask | null = null;

interface SlaCandidate {
  tenantId: string;
  obligationId: number;
  obligationType: string;
  contractId: number;
  assigneeUserId: number | null;
  titleEn: string;
  dueDate: string;
  daysOverdue: number;
  tierDay: number;
}

interface SlaCheckResult {
  candidates?: SlaCandidate[];
}

async function dispatchCandidate(c: SlaCandidate): Promise<void> {
  try {
    await db.callFunction(
      'fn_obligation_sla_dispatch',
      [c.obligationId, c.tierDay],
      { actorId: SYSTEM_ACTOR_ID, tenantId: c.tenantId },
    );
    logger.info(
      {
        action: 'obligationSlaWorker.dispatched',
        obligationId: c.obligationId,
        tierDay: c.tierDay,
        daysOverdue: c.daysOverdue,
        obligationType: c.obligationType,
      },
      'Auto-escalated obligation',
    );
  } catch (err) {
    logger.warn(
      {
        action: 'obligationSlaWorker.dispatchFailed',
        obligationId: c.obligationId,
        tierDay: c.tierDay,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage:
          err instanceof Error ? err.message.slice(0, 200) : String(err).slice(0, 200),
      },
      'Obligation SLA dispatch failed (non-fatal)',
    );
  }
}

async function runTick(): Promise<void> {
  let result: SlaCheckResult | null = null;
  try {
    result = await db.callFunction<SlaCheckResult>(
      'fn_obligation_sla_check',
      [DEFAULT_LIMIT],
      { actorId: SYSTEM_ACTOR_ID },
    );
  } catch (err) {
    logger.error(
      {
        action: 'obligationSlaWorker.checkFailed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to fetch obligation SLA candidates',
    );
    return;
  }

  const candidates = result?.candidates ?? [];
  if (candidates.length === 0) {
    logger.debug(
      { action: 'obligationSlaWorker.noCandidates' },
      'No obligation SLA candidates',
    );
    return;
  }

  logger.info(
    { action: 'obligationSlaWorker.batchProcessing', count: candidates.length },
    'Processing obligation SLA batch',
  );

  const limit = pLimit(CONCURRENCY);
  await Promise.all(candidates.map((c) => limit(() => dispatchCandidate(c))));
}

export function startObligationSlaEscalationWorker(): void {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'obligationSlaWorker.start' },
      'Test mode — obligation SLA worker skipped',
    );
    return;
  }
  if (process.env['OBLIGATION_SLA_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'obligationSlaWorker.start' },
      'OBLIGATION_SLA_WORKER_ENABLED is not true — skipped',
    );
    return;
  }
  if (_cronTask) {
    logger.warn(
      { action: 'obligationSlaWorker.alreadyRunning' },
      'Obligation SLA worker already started',
    );
    return;
  }

  const schedule = process.env['OBLIGATION_SLA_CRON'] ?? DEFAULT_SCHEDULE_CRON;
  if (!cron.validate(schedule)) {
    logger.error(
      { action: 'obligationSlaWorker.start', schedule },
      'Invalid cron schedule — falling back to default',
    );
  }

  _cronTask = cron.schedule(cron.validate(schedule) ? schedule : DEFAULT_SCHEDULE_CRON, () => {
    void runTick().catch((err: unknown) => {
      logger.error(
        {
          action: 'obligationSlaWorker.cronError',
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'Unhandled error in obligation SLA worker cron',
      );
    });
  });

  logger.info(
    { action: 'obligationSlaWorker.started', schedule },
    'Obligation SLA escalation worker started',
  );

  process.once('SIGTERM', stopObligationSlaEscalationWorker);
  process.once('SIGINT', stopObligationSlaEscalationWorker);
}

export function stopObligationSlaEscalationWorker(): void {
  if (_cronTask) {
    _cronTask.stop();
    _cronTask = null;
    logger.info(
      { action: 'obligationSlaWorker.stopped' },
      'Obligation SLA worker stopped',
    );
  }
}

/**
 * Manual one-shot — exposed so an Executive/Admin can trigger an immediate
 * SLA evaluation (or the test suite can drive deterministic behaviour
 * without waiting for cron). Returns the number of candidates processed.
 */
export async function runObligationSlaTickOnce(): Promise<number> {
  let result: SlaCheckResult | null = null;
  try {
    result = await db.callFunction<SlaCheckResult>(
      'fn_obligation_sla_check',
      [DEFAULT_LIMIT],
      { actorId: SYSTEM_ACTOR_ID },
    );
  } catch (err) {
    logger.error(
      {
        action: 'obligationSlaWorker.runOnce.checkFailed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Manual SLA tick: check failed',
    );
    throw err;
  }
  const candidates = result?.candidates ?? [];
  const limit = pLimit(CONCURRENCY);
  await Promise.all(candidates.map((c) => limit(() => dispatchCandidate(c))));
  return candidates.length;
}
