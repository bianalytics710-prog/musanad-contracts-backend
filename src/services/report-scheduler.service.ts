/**
 * M20 / CR-L — Report Scheduler Service.
 *
 * Periodically scans report_template rows with is_scheduled=true + enabled=true
 * + is_active=true. For each row, ensures a node-cron task is scheduled per
 * its schedule_cron expression. The task simply enqueues a report_run by
 * calling fn_report_run_trigger(SYSTEM_ACTOR=0, p_template_id, p_parameters,
 * p_format, p_triggered_by='scheduled'). The report-run.worker picks the
 * pending run up via fn_report_run_pending_get on its next tick.
 *
 * Re-scan cadence: every 5 minutes (catches admin CRUD additions/removals).
 *
 * Guards:
 *   - NODE_ENV=test → no-op
 *   - REPORT_SCHEDULER_ENABLED != 'true' → no-op (default off in dev)
 *
 * Bootstrap actor: SYSTEM_ACTOR_ID = 0 (fn_report_run_trigger DB design §2.14
 * accepts p_triggered_by='scheduled' only when actor is system).
 *
 * Note: this service does NOT render reports itself — it only enqueues.
 * Rendering happens in report-run.worker.ts; dispatch (when configured)
 * also happens there.
 */
import cron, { type ScheduledTask } from 'node-cron';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';

const SYSTEM_ACTOR_ID = 0;
const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const RESCAN_CRON = '*/5 * * * *'; // every 5 minutes
const SCHEDULER_TIMEZONE = 'UTC';

interface ScheduledTemplate {
  id: number;
  templateId: string;
  reportKind: 'pdf' | 'excel' | 'both';
  scheduleCron: string;
  scheduleRecipients: string[] | null;
  isScheduled: boolean;
  enabled: boolean;
}

interface ScheduledTemplateListResult {
  data?: ScheduledTemplate[];
}

interface ScheduledEntry {
  task: ScheduledTask;
  cron: string;
  reportKind: 'pdf' | 'excel' | 'both';
}

const _scheduledTasks: Map<number, ScheduledEntry> = new Map();
let _rescanTask: ScheduledTask | null = null;

/**
 * Compute the default format for a scheduled run given the template's report_kind:
 *   excel → excel
 *   pdf   → pdf
 *   both  → pdf (PDF is the standard scheduled-dispatch format per AC#3)
 */
function defaultFormat(reportKind: 'pdf' | 'excel' | 'both'): 'pdf' | 'excel' {
  if (reportKind === 'excel') return 'excel';
  return 'pdf';
}

/**
 * Enqueue a single scheduled report run via fn_report_run_trigger.
 */
async function enqueueScheduledRun(t: ScheduledTemplate): Promise<void> {
  try {
    await db.callFunction(
      'fn_report_run_trigger',
      [
        SYSTEM_ACTOR_ID,
        t.id,
        '{}',
        defaultFormat(t.reportKind),
        'scheduled',
      ],
      { actorId: SYSTEM_ACTOR_ID, tenantId: ADNOC_TENANT_ID },
    );
    logger.info(
      {
        action: 'reportScheduler.enqueued',
        templateId: t.id,
        templateSlug: t.templateId,
        format: defaultFormat(t.reportKind),
      },
      'Scheduled report run enqueued',
    );
  } catch (err) {
    logger.error(
      {
        action: 'reportScheduler.enqueueFailed',
        templateId: t.id,
        templateSlug: t.templateId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message.slice(0, 200) : String(err).slice(0, 200),
      },
      'Failed to enqueue scheduled report run',
    );
  }
}

/**
 * Refresh node-cron task registrations from the current set of enabled
 * scheduled templates. Idempotent — diffs against _scheduledTasks.
 */
async function refreshSchedules(): Promise<void> {
  let result: ScheduledTemplateListResult | null = null;
  try {
    // Worker-context DEFINER fn (mig 275) — returns is_scheduled=true AND
    // enabled=true AND is_active=true rows across ALL tenants. fn_report_template_list
    // (INVOKER, requires report.template.manage) cannot be called from the
    // SYSTEM_ACTOR=0 worker context — see DEFECT-CRKL-SMOKE-1 and the M14 /
    // M16 worker-fn precedent (SECURITY DEFINER carve-out).
    result = await db.callFunction<ScheduledTemplateListResult>(
      'fn_report_template_list_scheduled_only',
      [],
      { actorId: SYSTEM_ACTOR_ID },
    );
  } catch (err) {
    logger.error(
      {
        action: 'reportScheduler.refreshFailed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to refresh report scheduler list',
    );
    return;
  }

  const list = result?.data ?? [];
  const scheduled = list.filter(
    (t) =>
      t.isScheduled === true &&
      t.enabled === true &&
      typeof t.scheduleCron === 'string' &&
      t.scheduleCron.trim().length > 0 &&
      cron.validate(t.scheduleCron),
  );

  const seenIds = new Set<number>();

  for (const t of scheduled) {
    seenIds.add(t.id);
    const existing = _scheduledTasks.get(t.id);
    if (existing && existing.cron === t.scheduleCron && existing.reportKind === t.reportKind) {
      continue; // unchanged
    }
    if (existing) {
      existing.task.stop();
      _scheduledTasks.delete(t.id);
    }
    const task = cron.schedule(
      t.scheduleCron,
      () => {
        void enqueueScheduledRun(t).catch(() => {});
      },
      { timezone: SCHEDULER_TIMEZONE },
    );
    _scheduledTasks.set(t.id, { task, cron: t.scheduleCron, reportKind: t.reportKind });
    logger.info(
      {
        action: 'reportScheduler.registered',
        templateId: t.id,
        templateSlug: t.templateId,
        cron: t.scheduleCron,
      },
      'Registered scheduled report task',
    );
  }

  // Remove tasks for templates that disappeared / disabled / deleted
  for (const [id, entry] of _scheduledTasks.entries()) {
    if (!seenIds.has(id)) {
      entry.task.stop();
      _scheduledTasks.delete(id);
      logger.info(
        { action: 'reportScheduler.unregistered', templateId: id },
        'Unregistered scheduled report task',
      );
    }
  }
}

export function startReportScheduler(): void {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info({ action: 'reportScheduler.start' }, 'Test mode — report scheduler skipped');
    return;
  }
  if (process.env['REPORT_SCHEDULER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'reportScheduler.start' },
      'REPORT_SCHEDULER_ENABLED is not true — skipped',
    );
    return;
  }
  if (_rescanTask) {
    logger.warn(
      { action: 'reportScheduler.alreadyRunning' },
      'Report scheduler already started',
    );
    return;
  }

  // Initial scan on boot — fire-and-forget
  void refreshSchedules();

  _rescanTask = cron.schedule(RESCAN_CRON, () => {
    void refreshSchedules().catch((err: unknown) => {
      logger.error(
        {
          action: 'reportScheduler.rescanError',
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'Unhandled error in report scheduler rescan',
      );
    });
  });

  logger.info(
    { action: 'reportScheduler.started', rescanCron: RESCAN_CRON, timezone: SCHEDULER_TIMEZONE },
    'Report scheduler started',
  );

  process.once('SIGTERM', stopReportScheduler);
  process.once('SIGINT', stopReportScheduler);
}

export function stopReportScheduler(): void {
  if (_rescanTask) {
    _rescanTask.stop();
    _rescanTask = null;
  }
  for (const entry of _scheduledTasks.values()) {
    entry.task.stop();
  }
  _scheduledTasks.clear();
  logger.info({ action: 'reportScheduler.stopped' }, 'Report scheduler stopped');
}
