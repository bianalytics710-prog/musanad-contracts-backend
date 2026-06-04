/**
 * Report run executor — shared between the cron worker and the inline
 * controller path.
 *
 * Given an already-created report_run row (status pending or generating),
 * runs the full render pipeline:
 *   1. fetch template (slug + display name)
 *   2. invoke fn_report_data_<slug> to fetch the envelope
 *   3. render PDF or XLSX via report-renderer
 *   4. upload bytes to Supabase Storage
 *   5. call fn_report_run_complete with terminal state
 *
 * Returns:
 *   { ok: true, storagePath, sizeBytes, mimeType }
 *   { ok: false, error }
 *
 * On any failure within steps 1-4, fn_report_run_complete('failed', error)
 * is called by this function before returning the error to the caller.
 */
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import {
  renderReportPdf,
  renderReportXlsx,
  type ReportRenderEnvelope,
} from './report-renderer.service';
import {
  buildReportOutputPath,
  uploadReportOutput,
} from './supabase-storage.service';

const SYSTEM_ACTOR_ID = 0;

export interface PendingRunRow {
  id: number;
  tenantId: string;
  reportTemplateId: number;
  format: 'pdf' | 'excel';
  parameters: Record<string, unknown>;
  triggeredBy: 'manual' | 'scheduled';
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

export interface ReportRunExecuteResult {
  ok: boolean;
  storagePath?: string;
  sizeBytes?: number;
  mimeType?: string;
  templateSlug?: string;
  displayNameEn?: string;
  error?: string;
  template?: ReportTemplate;
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
        action: 'reportRunExecutor.markFailedError',
        runId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to record failed terminal state',
    );
  }
}

export interface ExecuteOptions {
  /**
   * Actor id used to authenticate the inline render against fn_report_template_get_by_id
   * and the per-slug fn_report_data_<slug> functions. Defaults to SYSTEM_ACTOR_ID (the
   * scheduled-worker path). The synchronous-controller path passes the request's user id
   * so RLS + visibility gates clear.
   */
  actorId?: number;
}

/**
 * Execute a single report run end-to-end. Idempotent: the caller is
 * responsible for ensuring the row exists and is in pending/generating
 * state. On success the row will be transitioned to status='complete'
 * with outputUri populated. On failure, status='failed' with errorMessage.
 */
export async function executeReportRunRow(
  row: PendingRunRow,
  opts: ExecuteOptions = {},
): Promise<ReportRunExecuteResult> {
  const startMs = Date.now();
  const { id: runId, tenantId } = row;
  const actorId = opts.actorId ?? SYSTEM_ACTOR_ID;

  logger.info(
    {
      action: 'reportRunExecutor.start',
      runId,
      templateId: row.reportTemplateId,
      format: row.format,
      triggeredBy: row.triggeredBy,
    },
    'Executing report run',
  );

  // 1. Fetch template
  let template: ReportTemplate | null;
  try {
    template = await db.callFunction<ReportTemplate | null>(
      'fn_report_template_get_by_id',
      [actorId, row.reportTemplateId],
      { actorId, tenantId },
    );
  } catch (err) {
    const msg = err instanceof Error ? err.message.slice(0, 300) : String(err).slice(0, 300);
    await markFailed(runId, tenantId, `template_lookup_failed: ${msg}`);
    return { ok: false, error: `template_lookup_failed: ${msg}` };
  }
  if (!template) {
    await markFailed(runId, tenantId, 'template_not_found');
    return { ok: false, error: 'template_not_found' };
  }

  // 2. Invoke fn_report_data_<slug>
  const fnName = `fn_report_data_${template.dataSource}`;
  if (!/^fn_report_data_[a-z0-9_]+$/i.test(fnName)) {
    await markFailed(runId, tenantId, 'invalid_data_source_slug');
    return { ok: false, error: 'invalid_data_source_slug', template };
  }

  let envelope: ReportRenderEnvelope;
  try {
    const raw = await db.callFunction<ReportRenderEnvelope | null>(
      fnName,
      [actorId, row.parameters ? JSON.stringify(row.parameters) : '{}'],
      { actorId, tenantId },
    );
    if (!raw || typeof raw !== 'object') {
      throw new Error('data fn returned empty envelope');
    }
    envelope = raw;
  } catch (err) {
    const msg = err instanceof Error ? err.message.slice(0, 500) : String(err).slice(0, 500);
    await markFailed(runId, tenantId, `data_fn_failed: ${msg}`);
    return { ok: false, error: `data_fn_failed: ${msg}`, template };
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
    return { ok: false, error: `render_failed: ${msg}`, template };
  }

  // 4. Upload
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
    return { ok: false, error: `upload_failed: ${msg}`, template };
  }

  // 5. Mark complete
  try {
    await db.callFunction(
      'fn_report_run_complete',
      [runId, 'complete', storagePath, buffer.byteLength, null],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );
  } catch (err) {
    const msg = err instanceof Error ? err.message.slice(0, 300) : String(err).slice(0, 300);
    logger.error(
      {
        action: 'reportRunExecutor.completeFnFailed',
        runId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_report_run_complete (success path) failed',
    );
    // File was uploaded but DB state was not transitioned. Caller can still
    // mint a signed URL from storagePath.
    return {
      ok: false,
      error: `complete_fn_failed: ${msg}`,
      storagePath,
      sizeBytes: buffer.byteLength,
      mimeType,
      template,
    };
  }

  logger.info(
    {
      action: 'reportRunExecutor.complete',
      runId,
      format: row.format,
      sizeBytes: buffer.byteLength,
      durationMs: Date.now() - startMs,
    },
    'Report run complete',
  );

  return {
    ok: true,
    storagePath,
    sizeBytes: buffer.byteLength,
    mimeType,
    templateSlug: template.dataSource,
    displayNameEn: template.displayNameEn,
    template,
  };
}
