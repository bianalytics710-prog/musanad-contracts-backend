/**
 * Phase C — Risk Case auto-dismiss worker.
 *
 * Nightly cron that closes risk cases that nobody ever self-claimed.
 * A case left untouched for 14 days probably wasn't real — closing it
 * with closure_outcome='no_action' clears the queue without losing the
 * audit trail (the row stays in audit_log + risk_case_event).
 *
 * Guard rails:
 *   - assigned_user_id IS NULL (nobody self-claimed from the role pool)
 *   - status IN ('open','in_review') (not already decided)
 *   - created_at < now() - 14d
 *
 * Runs as SYSTEM_ACTOR_ID=0 so events show "system" rather than a
 * specific user. NODE_ENV=test → no-op (same pattern as the other workers).
 */
import cron, { type ScheduledTask } from 'node-cron';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';

const SYSTEM_ACTOR_ID = 0;
const STALE_DAYS = 14;
const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

let _cronTask: ScheduledTask | null = null;

async function runOnce(): Promise<void> {
  const startedAt = Date.now();
  try {
    const result = await db.callFunction<{ dismissedCount: number }>(
      'fn_risk_case_auto_dismiss_stale',
      [STALE_DAYS, SYSTEM_ACTOR_ID],
      { actorId: SYSTEM_ACTOR_ID, tenantId: ADNOC_TENANT_ID },
    );
    logger.info({
      action: 'risk_case.auto_dismiss.batch',
      durationMs: Date.now() - startedAt,
      dismissedCount: result?.dismissedCount ?? 0,
    });
  } catch (err) {
    logger.error({
      action: 'risk_case.auto_dismiss.batch.error',
      durationMs: Date.now() - startedAt,
      error: (err as Error).message,
    });
  }
}

export function startRiskCaseAutoDismissWorker(): void {
  if (process.env.NODE_ENV === 'test') {
    logger.info({ action: 'risk_case.auto_dismiss.start.skipped', reason: 'NODE_ENV=test' });
    return;
  }
  if (process.env.RISK_CASE_AUTO_DISMISS_ENABLED === 'false') {
    logger.info({ action: 'risk_case.auto_dismiss.start.skipped', reason: 'disabled_via_env' });
    return;
  }

  // Run nightly at 02:30 UTC. Cron expression: m h * * *
  _cronTask = cron.schedule('30 2 * * *', () => {
    void runOnce();
  }, { timezone: 'UTC' });

  logger.info({ action: 'risk_case.auto_dismiss.start', schedule: '30 2 * * * UTC' });
}

export function stopRiskCaseAutoDismissWorker(): void {
  if (_cronTask) {
    _cronTask.stop();
    _cronTask = null;
    logger.info({ action: 'risk_case.auto_dismiss.stop' });
  }
}
