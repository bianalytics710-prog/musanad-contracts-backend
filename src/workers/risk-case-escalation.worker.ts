/**
 * M19 / CR-K — Risk Case Escalation Worker.
 *
 * Every 5 minutes (configurable via RISK_CASE_ESCALATION_CRON env, default
 * '*&#47;5 * * * *'). Invokes the DEFINER fn_risk_case_escalation_check()
 * cross-tenant read to enumerate cases past their due_at + not snoozed +
 * not in terminal status. For each candidate, the worker sets the per-row
 * tenant GUC and calls fn_risk_case_escalate with the SYSTEM_ACTOR_ID
 * sentinel.
 *
 * Guards:
 *   - NODE_ENV=test → no-op
 *   - RISK_CASE_ESCALATION_WORKER_ENABLED != 'true' → no-op (default off in dev)
 *
 * Failure handling: each escalation attempt has its own try/catch. A failed
 * escalation (e.g. matrix not configured, cycle detected) logs a WARN and
 * moves on — the next tick re-evaluates.
 */
import cron, { type ScheduledTask } from 'node-cron';
import pLimit from 'p-limit';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';

const SYSTEM_ACTOR_ID = 0;
const CONCURRENCY = 2;
const DEFAULT_LIMIT = 100;
const DEFAULT_SCHEDULE_CRON = '*/5 * * * *'; // every 5 minutes

let _cronTask: ScheduledTask | null = null;

interface EscalationCandidate {
  id: number;
  tenantId: string;
  priority: string;
  assignedRole: string | null;
  currentDueAt: string;
}

interface EscalationCheckResult {
  candidates?: EscalationCandidate[];
}

async function escalateCandidate(c: EscalationCandidate): Promise<void> {
  try {
    await db.callFunction(
      'fn_risk_case_escalate',
      [SYSTEM_ACTOR_ID, c.id, 'auto-escalation: due_at exceeded'],
      { actorId: SYSTEM_ACTOR_ID, tenantId: c.tenantId },
    );
    logger.info(
      {
        action: 'riskCaseEscalationWorker.escalated',
        caseId: c.id,
        tenantId: c.tenantId,
        priority: c.priority,
        fromRole: c.assignedRole,
      },
      'Auto-escalated risk case',
    );
  } catch (err) {
    // Expected failures: P0001 (matrix not configured, cycle detected,
    // top-of-matrix). Log + continue — the case will be retried next tick
    // or remain at its current assignment.
    logger.warn(
      {
        action: 'riskCaseEscalationWorker.escalateFailed',
        caseId: c.id,
        tenantId: c.tenantId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message.slice(0, 200) : String(err).slice(0, 200),
      },
      'Auto-escalation failed (non-fatal)',
    );
  }
}

async function runTick(): Promise<void> {
  let result: EscalationCheckResult | null = null;
  try {
    // DEFINER + STABLE — cross-tenant. No tenantId GUC required for the check
    // itself; tenant context is established per-candidate before fn_escalate.
    result = await db.callFunction<EscalationCheckResult>(
      'fn_risk_case_escalation_check',
      [DEFAULT_LIMIT],
      { actorId: SYSTEM_ACTOR_ID },
    );
  } catch (err) {
    logger.error(
      {
        action: 'riskCaseEscalationWorker.checkFailed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to fetch escalation candidates',
    );
    return;
  }

  const candidates = result?.candidates ?? [];
  if (candidates.length === 0) {
    logger.debug({ action: 'riskCaseEscalationWorker.noCandidates' }, 'No escalation candidates');
    return;
  }

  logger.info(
    { action: 'riskCaseEscalationWorker.batchProcessing', count: candidates.length },
    'Processing escalation batch',
  );

  const limit = pLimit(CONCURRENCY);
  await Promise.all(candidates.map((c) => limit(() => escalateCandidate(c))));
}

export function startRiskCaseEscalationWorker(): void {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'riskCaseEscalationWorker.start' },
      'Test mode — risk case escalation worker skipped',
    );
    return;
  }
  if (process.env['RISK_CASE_ESCALATION_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'riskCaseEscalationWorker.start' },
      'RISK_CASE_ESCALATION_WORKER_ENABLED is not true — skipped',
    );
    return;
  }
  if (_cronTask) {
    logger.warn(
      { action: 'riskCaseEscalationWorker.alreadyRunning' },
      'Risk case escalation worker already started',
    );
    return;
  }

  const schedule = process.env['RISK_CASE_ESCALATION_CRON'] ?? DEFAULT_SCHEDULE_CRON;
  if (!cron.validate(schedule)) {
    logger.error(
      { action: 'riskCaseEscalationWorker.start', schedule },
      'Invalid cron schedule — falling back to default',
    );
  }

  _cronTask = cron.schedule(cron.validate(schedule) ? schedule : DEFAULT_SCHEDULE_CRON, () => {
    void runTick().catch((err: unknown) => {
      logger.error(
        {
          action: 'riskCaseEscalationWorker.cronError',
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'Unhandled error in escalation worker cron',
      );
    });
  });

  logger.info(
    { action: 'riskCaseEscalationWorker.started', schedule },
    'Risk case escalation worker started',
  );

  process.once('SIGTERM', stopRiskCaseEscalationWorker);
  process.once('SIGINT', stopRiskCaseEscalationWorker);
}

export function stopRiskCaseEscalationWorker(): void {
  if (_cronTask) {
    _cronTask.stop();
    _cronTask = null;
    logger.info(
      { action: 'riskCaseEscalationWorker.stopped' },
      'Risk case escalation worker stopped',
    );
  }
}
