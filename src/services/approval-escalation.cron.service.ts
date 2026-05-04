/**
 * Approval-escalation cron driver (M2 / S9).
 *
 * Scans `approval_step` rows where:
 *   status='pending'
 *   AND escalation_after_hours IS NOT NULL
 *   AND now() - created_at >= make_interval(hours => escalation_after_hours)
 * and calls `fn_approval_escalate(stepId)` for each match. fn_approval_escalate
 * is SECURITY DEFINER — only neondb_owner has EXECUTE — so the BE pool's
 * connection role (neondb_owner via DATABASE_URL) is what authorises the call.
 * No human user has approval.escalate (deliberately skipped — OI-12).
 *
 * Idempotency guarantee: fn_approval_escalate's pre-check (M2-NEW-3) ensures
 * a duplicate escalation peer is NOT inserted; the driver may safely retry.
 *
 * Default schedule: every 15 minutes (CLAUDE.md / Q6=A). Override via
 * APPROVAL_ESCALATION_INTERVAL_CRON env var. Disabled in NODE_ENV=test (the
 * smoke harness short-circuits).
 *
 * Q3-OI-C / db-design.md §3.fn_approval_escalate notes:
 *   - DRIVER lives in BE process; one driver per replica is fine because
 *     fn_approval_escalate is internally idempotent. If multi-replica drift
 *     becomes a concern, swap to a leader-election shim (e.g. pg_advisory_lock
 *     keyed on a sentinel BIGINT — out of scope for M2).
 */
import cron, { type ScheduledTask } from 'node-cron';
import { logger } from '../utils/logger.util';
import { pool } from '../database/config';
import * as approvalService from './approval.service';

interface CandidateRow {
  id: number;
  approval_chain_id: number;
  step_order: number;
  escalation_role: string | null;
  escalation_after_hours: number | null;
}

const DEFAULT_CRON = '*/15 * * * *';

/**
 * Default actorId used as the GUC value for fn_ calls. The cron driver
 * runs with no human session, so we pass NULL semantically — but
 * fn_approval_escalate ignores actor (system-only). We still need an
 * actorId for db.callFunction's optional GUC; using 0 is safe because:
 *   (a) RLS on approval_step does not require app.current_user_id for
 *       the SECURITY DEFINER fn_;
 *   (b) the function does not consult current_setting('app.current_user_id').
 * If a future audit row needs a real actor, surface the chain.initiated_by
 * inside the fn_ (as already designed: decided_by = chain.initiated_by).
 */
const SYSTEM_ACTOR_ID = 0;

let task: ScheduledTask | null = null;

/**
 * One escalation sweep — exposed for tests & startup self-test. Returns the
 * list of stepIds processed (whether or not escalation actually fired).
 */
export const runEscalationSweep = async (): Promise<number[]> => {
  const startTime = Date.now();
  const candidates: CandidateRow[] = [];
  try {
    // Read-only query; bypass GUC because we run as the connection role.
    const res = await pool().query<CandidateRow>(
      `SELECT id, approval_chain_id, step_order, escalation_role, escalation_after_hours
         FROM approval_step
        WHERE status = 'pending'
          AND is_active = TRUE
          AND escalation_role IS NOT NULL
          AND escalation_after_hours IS NOT NULL
          AND now() - created_at >= make_interval(hours => escalation_after_hours)
        ORDER BY id ASC
        LIMIT 200`,
    );
    candidates.push(...res.rows);
  } catch (err) {
    logger.error(
      {
        action: 'approvalEscalationCron.scan',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        message: err instanceof Error ? err.message : String(err),
      },
      'Escalation candidate scan failed',
    );
    return [];
  }

  if (candidates.length === 0) {
    logger.debug(
      {
        action: 'approvalEscalationCron.sweep',
        candidates: 0,
        durationMs: Date.now() - startTime,
      },
      'No escalation candidates',
    );
    return [];
  }

  const processed: number[] = [];
  for (const row of candidates) {
    try {
      const result = await approvalService.escalate(SYSTEM_ACTOR_ID, row.id);
      processed.push(row.id);
      logger.info(
        {
          action: 'approvalEscalationCron.escalate',
          stepId: row.id,
          chainId: row.approval_chain_id,
          stepOrder: row.step_order,
          escalationRole: row.escalation_role,
          newPeerStepId: result?.newPeerStepId ?? null,
          decisionId: result?.decisionId ?? null,
        },
        'Escalation peer created',
      );
    } catch (err) {
      // fn_approval_escalate raises if the step is no longer pending or the
      // peer already exists (idempotency guard). Both are non-fatal — log and
      // continue.
      logger.warn(
        {
          action: 'approvalEscalationCron.escalate_failed',
          stepId: row.id,
          chainId: row.approval_chain_id,
          stepOrder: row.step_order,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
          message: err instanceof Error ? err.message : String(err),
        },
        'Escalation call failed (non-fatal)',
      );
    }
  }

  logger.info(
    {
      action: 'approvalEscalationCron.sweep',
      candidates: candidates.length,
      processed: processed.length,
      durationMs: Date.now() - startTime,
    },
    'Escalation sweep complete',
  );
  return processed;
};

/**
 * Start the cron driver. Idempotent; calling twice is a no-op after the
 * first start. NODE_ENV=test short-circuits (smoke harness owns scheduling).
 */
export const startApprovalEscalationCron = (): ScheduledTask | null => {
  if (process.env.NODE_ENV === 'test') {
    logger.info(
      { action: 'approvalEscalationCron.skip', reason: 'NODE_ENV=test' },
      'Approval escalation cron disabled in test env',
    );
    return null;
  }
  if (task) {
    logger.warn(
      { action: 'approvalEscalationCron.start' },
      'Approval escalation cron already running — skipping duplicate start',
    );
    return task;
  }
  const expression = process.env.APPROVAL_ESCALATION_INTERVAL_CRON ?? DEFAULT_CRON;
  if (!cron.validate(expression)) {
    logger.error(
      {
        action: 'approvalEscalationCron.invalid_expression',
        expression,
      },
      'APPROVAL_ESCALATION_INTERVAL_CRON is not a valid cron expression — driver NOT started',
    );
    return null;
  }
  task = cron.schedule(
    expression,
    () => {
      void runEscalationSweep().catch((err) => {
        logger.error(
          {
            action: 'approvalEscalationCron.unhandled',
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
            message: err instanceof Error ? err.message : String(err),
          },
          'Unhandled escalation sweep error',
        );
      });
    },
    { scheduled: true },
  );
  logger.info(
    { action: 'approvalEscalationCron.start', expression },
    'Approval escalation cron started',
  );
  return task;
};

/** Stop the cron driver. Used by graceful shutdown + tests. */
export const stopApprovalEscalationCron = (): void => {
  if (task) {
    task.stop();
    task = null;
    logger.info(
      { action: 'approvalEscalationCron.stop' },
      'Approval escalation cron stopped',
    );
  }
};
