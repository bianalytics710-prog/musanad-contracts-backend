/**
 * M20 / CR-L — Report Run Worker.
 *
 * node-cron-driven worker that:
 *   1. Picks up pending report_run rows via fn_report_run_pending_get(5)
 *      (DEFINER + FOR UPDATE SKIP LOCKED — atomically flips pending→generating).
 *   2. For each: looks up template → invokes fn_report_data_<slug> to fetch
 *      the data envelope → renders PDF / XLSX via report-renderer.service →
 *      uploads to Supabase Storage → calls fn_report_run_complete(... 'complete', uri, size).
 *   3. On failure at any step: calls fn_report_run_complete(... 'failed', errorMessage).
 *   4. If template is_scheduled and run.triggered_by='scheduled', dispatches
 *      the resulting Supabase path via fn_notification_send to scheduleRecipients.
 *
 * Cadence: every 10s.
 * Concurrency: p-limit(2) per tick.
 *
 * Guards:
 *   - NODE_ENV=test → no-op
 *   - REPORT_RUN_WORKER_ENABLED != 'true' → no-op (default off in dev)
 *
 * Bootstrap actor: SYSTEM_ACTOR_ID = 0 (DB design §2.15 NULLIF→NULL pattern).
 */
import cron, { type ScheduledTask } from 'node-cron';
import pLimit from 'p-limit';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { executeReportRunRow } from '../services/report-run-executor.service';

const SYSTEM_ACTOR_ID = 0;
const BATCH_SIZE = 5;
const CONCURRENCY = 2;
const POLL_SCHEDULE_CRON = '*/10 * * * * *'; // every 10 seconds (node-cron 6-field)

let _cronTask: ScheduledTask | null = null;

// ----------------------------------------------------------------
// Types matching fn_report_run_pending_get output
// ----------------------------------------------------------------

interface PendingRunRow {
  id: number;
  tenantId: string;
  reportTemplateId: number;
  format: 'pdf' | 'excel';
  parameters: Record<string, unknown>;
  triggeredBy: 'manual' | 'scheduled';
}

interface PendingRunsResult {
  runs?: PendingRunRow[];
}

// ----------------------------------------------------------------
// Per-run pipeline
// ----------------------------------------------------------------

async function processRun(row: PendingRunRow): Promise<void> {
  const runId = row.id;
  const tenantId = row.tenantId;

  // CR-V: module-enabled guard — skip tick if 'reports' module is disabled for this tenant.
  try {
    const enabled = await db.callFunction<boolean>(
      'fn_module_enabled',
      [tenantId, 'reports'],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );
    if (!enabled) {
      logger.info({ action: 'reportRunWorker.moduleDisabled', moduleKey: 'reports', tenantId, runId },
        'module disabled, worker tick skipped');
      return;
    }
  } catch (guardErr) {
    logger.warn({ action: 'reportRunWorker.moduleGuardError', runId,
      errorType: guardErr instanceof Error ? guardErr.name : 'UNKNOWN' },
      'module guard check failed — continuing (fail-open)');
  }

  // Render + persist via shared executor (terminal-state transitions are done there)
  const result = await executeReportRunRow(row);
  if (!result.ok) return;

  // Scheduled dispatch — wire to existing M16 notification stack.
  if (
    row.triggeredBy === 'scheduled' &&
    result.template?.isScheduled &&
    Array.isArray(result.template?.scheduleRecipients) &&
    result.template.scheduleRecipients.length > 0 &&
    result.storagePath
  ) {
    for (const recipient of result.template.scheduleRecipients) {
      try {
        // v2 (mig 582) — go through fn_notification_dispatch instead of
        // calling fn_notification_send directly. The 'report.delivered'
        // seed rule has recipient_type='context' value='caller', so the
        // recipient email passed in is honored. Admin can add more
        // recipients via /admin/notification-rules without touching code.
        await db.callFunction(
          'fn_notification_dispatch',
          [
            SYSTEM_ACTOR_ID,
            'report.delivered',
            JSON.stringify({
              subject: `Scheduled report ready: ${result.template.displayNameEn}`,
              bodyRendered: `Your scheduled report (${result.template.displayNameEn}) is ready at ${result.storagePath ?? ''}.`,
              runId,
              templateId: result.template.templateId,
              displayNameEn: result.template.displayNameEn,
              format: row.format,
              storagePath: result.storagePath,
            }),
            'system',
            'medium',
            null,
            recipient,
          ],
          { actorId: SYSTEM_ACTOR_ID, tenantId },
        );
      } catch (notifErr) {
        logger.warn(
          {
            action: 'reportRunWorker.dispatchFailed',
            runId,
            recipient,
            errorType: notifErr instanceof Error ? notifErr.name : 'UNKNOWN',
          },
          'Scheduled report dispatch failed (non-fatal)',
        );
      }
    }
  }
}

// ----------------------------------------------------------------
// Batch driver
// ----------------------------------------------------------------

async function processBatch(): Promise<void> {
  let result: PendingRunsResult | null = null;
  try {
    // DEFINER fn — atomically flips pending → generating via FOR UPDATE SKIP LOCKED
    result = await db.callFunction<PendingRunsResult>(
      'fn_report_run_pending_get',
      [BATCH_SIZE],
      { actorId: SYSTEM_ACTOR_ID },
    );
  } catch (err) {
    logger.error(
      {
        action: 'reportRunWorker.fetchFailed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to fetch pending report runs',
    );
    return;
  }

  const runs = result?.runs ?? [];
  if (runs.length === 0) return;

  logger.info(
    { action: 'reportRunWorker.batchProcessing', count: runs.length },
    'Processing report run batch',
  );

  const limit = pLimit(CONCURRENCY);
  await Promise.all(
    runs.map((run) =>
      limit(() => processRun(run)).catch((err: unknown) => {
        logger.error(
          {
            action: 'reportRunWorker.pLimitError',
            runId: run.id,
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
          },
          'Unhandled error in p-limit report run wrapper',
        );
      }),
    ),
  );
}

// ----------------------------------------------------------------
// Public API: start / stop
// ----------------------------------------------------------------

export function startReportRunWorker(): void {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info({ action: 'reportRunWorker.start' }, 'Test mode — report run worker skipped');
    return;
  }
  if (process.env['REPORT_RUN_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'reportRunWorker.start' },
      'REPORT_RUN_WORKER_ENABLED is not true — skipped',
    );
    return;
  }
  if (_cronTask) {
    logger.warn(
      { action: 'reportRunWorker.alreadyRunning' },
      'Report run worker already started',
    );
    return;
  }

  _cronTask = cron.schedule(POLL_SCHEDULE_CRON, () => {
    void processBatch().catch((err: unknown) => {
      logger.error(
        {
          action: 'reportRunWorker.cronError',
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'Unhandled error in report run worker cron',
      );
    });
  });

  logger.info(
    { action: 'reportRunWorker.started', schedule: POLL_SCHEDULE_CRON },
    'Report run worker started',
  );

  process.once('SIGTERM', stopReportRunWorker);
  process.once('SIGINT', stopReportRunWorker);
}

export function stopReportRunWorker(): void {
  if (_cronTask) {
    _cronTask.stop();
    _cronTask = null;
    logger.info({ action: 'reportRunWorker.stopped' }, 'Report run worker stopped');
  }
}
