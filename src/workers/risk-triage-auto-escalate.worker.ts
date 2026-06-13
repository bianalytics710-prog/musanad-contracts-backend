/**
 * Phase D (mig 647, 2026-06-13) — Risk Triage Auto-Escalate Worker.
 *
 * Daily node-cron job. Invokes fn_risk_triage_auto_escalate() which finds
 * Tier-2 risk cases (metadata.tier=2, status='open'|'in_review') that have
 * been sitting past system_setting.tier2AutoEscalateDays without exec
 * action, stamps the dedupe marker, and writes a risk_case_event audit row.
 *
 * The DB fn returns the list of caseIds + tenantIds it touched; this worker
 * just logs them. Notification fan-out (alert platform_admin + executive)
 * lives at the BE layer to avoid coupling the fn to the notification_rule
 * infrastructure — wire that here when the user wants it.
 *
 * Mirrors the existing risk-case-escalation.worker pattern (node-cron with
 * env-gated start, SIGTERM/SIGINT cleanup, test no-op).
 *
 * Guards:
 *   - NODE_ENV=test → no-op
 *   - RISK_TRIAGE_AUTO_ESCALATE_WORKER_ENABLED != 'true' → no-op
 */
import cron, { type ScheduledTask } from 'node-cron';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';

const SYSTEM_ACTOR_ID = 0;
const DEFAULT_SCHEDULE_CRON = '0 6 * * *'; // 06:00 UTC daily

let _cronTask: ScheduledTask | null = null;

interface AutoEscalateResult {
  thresholdDays: number;
  count: number;
  caseIds: number[];
  tenantIds: string[];
}

async function runTick(): Promise<void> {
  try {
    const result = await db.callFunction<AutoEscalateResult>(
      'fn_risk_triage_auto_escalate',
      [],
      { actorId: SYSTEM_ACTOR_ID },
    );
    if (result.count > 0) {
      logger.info(
        {
          action: 'riskTriageAutoEscalateWorker.escalated',
          count: result.count,
          thresholdDays: result.thresholdDays,
          caseIds: result.caseIds,
        },
        'Auto-escalated Tier-2 risk cases past unactioned threshold',
      );
    } else {
      logger.debug(
        {
          action: 'riskTriageAutoEscalateWorker.noCandidates',
          thresholdDays: result.thresholdDays,
        },
        'No Tier-2 cases needed escalation this tick',
      );
    }
  } catch (err) {
    logger.error(
      {
        action: 'riskTriageAutoEscalateWorker.tickFailed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message.slice(0, 200) : String(err).slice(0, 200),
      },
      'fn_risk_triage_auto_escalate call failed',
    );
  }
}

export function startRiskTriageAutoEscalateWorker(): void {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'riskTriageAutoEscalateWorker.start' },
      'Test mode — risk triage auto-escalate worker skipped',
    );
    return;
  }
  if (process.env['RISK_TRIAGE_AUTO_ESCALATE_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'riskTriageAutoEscalateWorker.start' },
      'RISK_TRIAGE_AUTO_ESCALATE_WORKER_ENABLED is not true — skipped',
    );
    return;
  }
  if (_cronTask) {
    logger.warn(
      { action: 'riskTriageAutoEscalateWorker.alreadyRunning' },
      'Risk triage auto-escalate worker already started',
    );
    return;
  }

  const schedule = process.env['RISK_TRIAGE_AUTO_ESCALATE_CRON'] ?? DEFAULT_SCHEDULE_CRON;
  if (!cron.validate(schedule)) {
    logger.error(
      { action: 'riskTriageAutoEscalateWorker.start', schedule },
      'Invalid cron schedule — falling back to default',
    );
  }

  _cronTask = cron.schedule(cron.validate(schedule) ? schedule : DEFAULT_SCHEDULE_CRON, () => {
    void runTick().catch((err: unknown) => {
      logger.error(
        {
          action: 'riskTriageAutoEscalateWorker.cronError',
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'Unhandled error in risk triage auto-escalate cron',
      );
    });
  });

  logger.info(
    { action: 'riskTriageAutoEscalateWorker.started', schedule },
    'Risk triage auto-escalate worker started',
  );

  process.once('SIGTERM', stopRiskTriageAutoEscalateWorker);
  process.once('SIGINT', stopRiskTriageAutoEscalateWorker);
}

export function stopRiskTriageAutoEscalateWorker(): void {
  if (_cronTask) {
    _cronTask.stop();
    _cronTask = null;
    logger.info(
      { action: 'riskTriageAutoEscalateWorker.stopped' },
      'Risk triage auto-escalate worker stopped',
    );
  }
}
