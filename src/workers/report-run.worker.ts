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
import {
  renderReportPdf,
  renderReportXlsx,
  type ReportRenderEnvelope,
} from '../services/report-renderer.service';
import {
  buildReportOutputPath,
  uploadReportOutput,
} from '../services/supabase-storage.service';

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

interface ReportTemplate {
  id: number;
  templateId: string;
  displayNameEn: string;
  dataSource: string;
  reportKind: 'pdf' | 'excel' | 'both';
  isScheduled?: boolean;
  scheduleRecipients?: string[] | null;
}

// ----------------------------------------------------------------
// Per-run pipeline
// ----------------------------------------------------------------

async function processRun(row: PendingRunRow): Promise<void> {
  const startMs = Date.now();
  const runId = row.id;
  const tenantId = row.tenantId;

  logger.info(
    {
      action: 'reportRunWorker.processRun',
      runId,
      templateId: row.reportTemplateId,
      format: row.format,
      triggeredBy: row.triggeredBy,
    },
    'Processing report run',
  );

  try {
    // 1. Fetch template for slug + displayName
    const template = await db.callFunction<ReportTemplate | null>(
      'fn_report_template_get_by_id',
      [SYSTEM_ACTOR_ID, row.reportTemplateId],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );
    if (!template) {
      await markFailed(runId, tenantId, 'template_not_found');
      return;
    }

    // 2. Invoke fn_report_data_<slug> to fetch envelope
    const fnName = `fn_report_data_${template.dataSource}`;
    if (!/^fn_report_data_[a-z0-9_]+$/i.test(fnName)) {
      await markFailed(runId, tenantId, 'invalid_data_source_slug');
      return;
    }

    let envelope: ReportRenderEnvelope;
    try {
      const raw = await db.callFunction<ReportRenderEnvelope | null>(
        fnName,
        [SYSTEM_ACTOR_ID, row.parameters ? JSON.stringify(row.parameters) : '{}'],
        { actorId: SYSTEM_ACTOR_ID, tenantId },
      );
      if (!raw || typeof raw !== 'object') {
        throw new Error('data fn returned empty envelope');
      }
      envelope = raw;
    } catch (err) {
      const msg = err instanceof Error ? err.message.slice(0, 500) : String(err).slice(0, 500);
      await markFailed(runId, tenantId, `data_fn_failed: ${msg}`);
      return;
    }

    // 3. Render
    const triggeredAt = new Date().toISOString();
    let buffer: Buffer;
    let mimeType: string;
    try {
      if (row.format === 'pdf') {
        buffer = await renderReportPdf(envelope, {
          slug: template.dataSource,
          displayNameEn: template.displayNameEn,
          triggeredAt,
        });
        mimeType = 'application/pdf';
      } else {
        buffer = await renderReportXlsx(envelope, {
          slug: template.dataSource,
          displayNameEn: template.displayNameEn,
          triggeredAt,
        });
        mimeType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message.slice(0, 500) : String(err).slice(0, 500);
      await markFailed(runId, tenantId, `render_failed: ${msg}`);
      return;
    }

    // 4. Upload to Supabase Storage
    const storagePath = buildReportOutputPath({
      tenantId,
      templateId: row.reportTemplateId,
      runId,
      format: row.format,
    });
    try {
      await uploadReportOutput({ storagePath, buffer, mimeType });
    } catch (err) {
      const msg = err instanceof Error ? err.message.slice(0, 500) : String(err).slice(0, 500);
      await markFailed(runId, tenantId, `upload_failed: ${msg}`);
      return;
    }

    // 5. Mark complete
    try {
      await db.callFunction(
        'fn_report_run_complete',
        [runId, 'complete', storagePath, buffer.byteLength, null],
        { actorId: SYSTEM_ACTOR_ID, tenantId },
      );
    } catch (err) {
      logger.error(
        {
          action: 'reportRunWorker.completeFnFailed',
          runId,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'fn_report_run_complete (success path) failed',
      );
      return;
    }

    // 6. Scheduled dispatch — wire to existing M16 notification stack.
    //    Best-effort: a dispatch failure does not roll back the report run.
    if (
      row.triggeredBy === 'scheduled' &&
      template.isScheduled &&
      Array.isArray(template.scheduleRecipients) &&
      template.scheduleRecipients.length > 0
    ) {
      for (const recipient of template.scheduleRecipients) {
        try {
          await db.callFunction(
            'fn_notification_send',
            [
              SYSTEM_ACTOR_ID,
              tenantId,
              recipient,
              'email',
              'report_scheduled_delivery',
              JSON.stringify({
                runId,
                templateId: template.templateId,
                displayNameEn: template.displayNameEn,
                format: row.format,
                storagePath,
              }),
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

    logger.info(
      {
        action: 'reportRunWorker.processRunComplete',
        runId,
        format: row.format,
        sizeBytes: buffer.byteLength,
        durationMs: Date.now() - startMs,
      },
      'Report run complete',
    );
  } catch (err) {
    // Defensive — every internal step has its own catch. This handles
    // anything that slipped through.
    const msg = err instanceof Error ? err.message.slice(0, 500) : String(err).slice(0, 500);
    logger.error(
      {
        action: 'reportRunWorker.processRunUnhandled',
        runId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Unhandled error processing report run',
    );
    await markFailed(runId, tenantId, `unhandled: ${msg}`).catch(() => {});
  }
}

async function markFailed(runId: number, tenantId: string, errorMessage: string): Promise<void> {
  try {
    await db.callFunction(
      'fn_report_run_complete',
      [runId, 'failed', null, null, errorMessage],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );
  } catch (err) {
    logger.error(
      {
        action: 'reportRunWorker.markFailedError',
        runId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to record failed terminal state',
    );
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
