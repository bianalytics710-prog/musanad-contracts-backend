/**
 * M11 — Document Ingestion Worker (CR-D0).
 *
 * Cadence: every 30s (configurable via system_setting 'ingestion.worker.poll_interval_seconds').
 * Concurrency: p-limit(2) — at most 2 parallel extractions per tick.
 *
 * Per tick:
 *   1. SELECT … FOR UPDATE SKIP LOCKED pending contract_version rows (LIMIT 2).
 *   2. For each: SET GUC context → fn_contract_version_ingest → extractDocument.
 *   3. On success → fn_contract_version_ingestion_complete.
 *   4. On error   → fn_contract_version_ingestion_fail (retry if attempt < 2; terminal if >= 2).
 *   5. For each low-confidence page → fn_ingestion_review_queue_record.
 *
 * Test mode: NODE_ENV=test → no-op (skip registration entirely).
 * Guard: INGESTION_WORKER_ENABLED=true required to start (default off in dev).
 *
 * Bootstrap actor: system user id 1 (SYSTEM_ACTOR_ID) — same pattern as M4
 * cron drivers. Tenant: ADNOC singleton UUID.
 */

import cron, { type ScheduledTask } from 'node-cron';
import pLimit from 'p-limit';
import { pool } from '../database/config';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { extractDocument } from '../services/document-ingestion.service';
import type { LowConfidencePage } from '../types/document-ingestion.types';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const SYSTEM_ACTOR_ID = 1;
const DEFAULT_POLL_SECONDS = 30;
const DEFAULT_CONCURRENCY = 2;
const DEFAULT_MAX_ATTEMPTS = 3;

let task: ScheduledTask | null = null;

interface PendingVersionRow {
  id: number;
  contract_id: number;
  version_number: number;
  file_uri: string | null;
  file_mime: string | null;
  tenant_id: string | null;
  ingestion_attempt_count: number;
}

/**
 * Fetch pending jobs using SELECT … FOR UPDATE SKIP LOCKED to prevent
 * concurrent worker races (S2-17 concurrency primitive).
 */
async function fetchPendingJobs(): Promise<PendingVersionRow[]> {
  const client = await pool().connect();
  try {
    await client.query('BEGIN');
    // Note: contract_version does not have file_uri / file_mime columns — the
    // file is linked via contract_attachment. We join to get the latest active
    // attachment for this version. If no attachment is found, skip.
    const res = await client.query<PendingVersionRow>(
      `SELECT cv.id,
              cv.contract_id,
              cv.version_number,
              ca.storage_path AS file_uri,
              ca.mime_type    AS file_mime,
              c.tenant_id     AS tenant_id,
              cv.ingestion_attempt_count
         FROM contract_version cv
         JOIN contract c ON c.id = cv.contract_id
         LEFT JOIN LATERAL (
           SELECT storage_path, mime_type
             FROM contract_attachment
            WHERE contract_id = cv.contract_id
              AND is_active = TRUE
            ORDER BY created_at DESC
            LIMIT 1
         ) ca ON TRUE
        WHERE cv.ingestion_status = 'pending'
          AND cv.ingestion_attempt_count < $1
        ORDER BY cv.id ASC
        LIMIT $2
        FOR UPDATE OF cv SKIP LOCKED`,
      [DEFAULT_MAX_ATTEMPTS, DEFAULT_CONCURRENCY],
    );
    await client.query('COMMIT');
    return res.rows;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    logger.error(
      { action: 'ingestionWorker.fetch_failed', errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'Failed to fetch pending ingestion jobs',
    );
    return [];
  } finally {
    client.release();
  }
}

/**
 * Process a single contract_version row through the extraction pipeline.
 */
async function processJob(row: PendingVersionRow): Promise<void> {
  const contractVersionId = row.id;
  const tenantId = row.tenant_id ?? ADNOC_TENANT_ID;

  // CR-V: module-enabled guard — skip if 'impact_signals' module is disabled.
  try {
    const enabled = await db.callFunction<boolean>(
      'fn_module_enabled',
      [tenantId, 'impact_signals'],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );
    if (!enabled) {
      logger.info({ action: 'ingestionWorker.moduleDisabled', moduleKey: 'impact_signals',
        tenantId, contractVersionId }, 'module disabled, worker tick skipped');
      return;
    }
  } catch (guardErr) {
    logger.warn({ action: 'ingestionWorker.moduleGuardError', contractVersionId,
      errorType: guardErr instanceof Error ? guardErr.name : 'UNKNOWN' },
      'module guard check failed — continuing (fail-open)');
  }

  logger.info(
    { action: 'ingestionWorker.job_start', contractVersionId, tenantId },
    'Starting ingestion job',
  );

  // 1. fn_contract_version_ingest — state flip to 'extracting'
  try {
    await db.callFunction(
      'fn_contract_version_ingest',
      [contractVersionId],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );
  } catch (err) {
    // If already extracting/complete, log and skip
    logger.warn(
      {
        action: 'ingestionWorker.ingest_fn_failed',
        contractVersionId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_contract_version_ingest failed — skipping job',
    );
    return;
  }

  // 2. Extract document
  if (!row.file_uri || !row.file_mime) {
    // No file attached — mark as failed immediately
    await failJob(contractVersionId, tenantId, 'No file attachment found for ingestion');
    return;
  }

  let result;
  try {
    result = await extractDocument({
      contractVersionId,
      contractId: row.contract_id,
      versionNumber: row.version_number,
      fileUri: row.file_uri,
      fileMime: row.file_mime,
      actorUserId: SYSTEM_ACTOR_ID,
      tenantId,
    });
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    await failJob(contractVersionId, tenantId, errorMsg);
    return;
  }

  // 3. On success → fn_contract_version_ingestion_complete
  try {
    await db.callFunction(
      'fn_contract_version_ingestion_complete',
      [
        contractVersionId,
        result.extractedTextUri,
        result.pageCount,
        result.ocrUsed,
        result.ocrConfidenceAvg ?? null,
        result.extractionEngine,
      ],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );
  } catch (err) {
    logger.error(
      {
        action: 'ingestionWorker.complete_fn_failed',
        contractVersionId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_contract_version_ingestion_complete failed',
    );
    await failJob(contractVersionId, tenantId, 'Failed to persist completion state');
    return;
  }

  // 4. Record low-confidence pages in ingestion_review_queue
  for (const page of result.lowConfidencePages) {
    await recordReviewPage(contractVersionId, tenantId, page);
  }

  logger.info(
    {
      action: 'ingestionWorker.job_complete',
      contractVersionId,
      engine: result.extractionEngine,
      pageCount: result.pageCount,
      lowConfidenceCount: result.lowConfidencePages.length,
    },
    'Ingestion job completed',
  );
}

async function failJob(
  contractVersionId: number,
  tenantId: string,
  errorMessage: string,
): Promise<void> {
  try {
    await db.callFunction(
      'fn_contract_version_ingestion_fail',
      [contractVersionId, errorMessage.slice(0, 2000)],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );
  } catch (err) {
    logger.error(
      {
        action: 'ingestionWorker.fail_fn_failed',
        contractVersionId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_contract_version_ingestion_fail also failed — state may be stuck',
    );
  }
}

async function recordReviewPage(
  contractVersionId: number,
  tenantId: string,
  page: LowConfidencePage,
): Promise<void> {
  try {
    await db.callFunction(
      'fn_ingestion_review_queue_record',
      [
        tenantId,
        contractVersionId,
        page.pageNo,
        page.tesseractConfidence ?? null,
        page.tesseractText ?? null,
        page.gpt4oText ?? null,
        page.gpt4oUsed,
        page.initialReviewStatus,
      ],
      { actorId: SYSTEM_ACTOR_ID, tenantId },
    );
  } catch (err) {
    logger.warn(
      {
        action: 'ingestionWorker.review_queue_record_failed',
        contractVersionId,
        pageNo: page.pageNo,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_ingestion_review_queue_record failed (non-fatal)',
    );
  }
}

/**
 * Run one polling sweep — fetch + process pending jobs.
 */
export async function runIngestionSweep(): Promise<{ processed: number; failed: number }> {
  const startedAt = Date.now();
  const stats = { processed: 0, failed: 0 };

  const jobs = await fetchPendingJobs();
  if (jobs.length === 0) return stats;

  const limit = pLimit(DEFAULT_CONCURRENCY);

  await Promise.all(
    jobs.map((row) =>
      limit(async () => {
        try {
          await processJob(row);
          stats.processed += 1;
        } catch (err) {
          stats.failed += 1;
          logger.error(
            {
              action: 'ingestionWorker.job_failed',
              contractVersionId: row.id,
              errorType: err instanceof Error ? err.name : 'UNKNOWN',
            },
            'Ingestion job failed',
          );
        }
      }),
    ),
  );

  logger.info(
    {
      action: 'ingestionWorker.sweep',
      ...stats,
      durationMs: Date.now() - startedAt,
    },
    'Ingestion sweep complete',
  );

  return stats;
}

/**
 * Start the ingestion worker cron schedule.
 * No-op in NODE_ENV=test.
 * Requires INGESTION_WORKER_ENABLED=true.
 */
export function startIngestionWorker(): ScheduledTask | null {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'ingestionWorker.skip', reason: 'NODE_ENV=test' },
      'Ingestion worker disabled in test env',
    );
    return null;
  }

  if (process.env['INGESTION_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'ingestionWorker.skip', reason: 'INGESTION_WORKER_ENABLED!=true' },
      'Ingestion worker not enabled (set INGESTION_WORKER_ENABLED=true to enable)',
    );
    return null;
  }

  if (task) {
    logger.warn(
      { action: 'ingestionWorker.start' },
      'Already running — skipping duplicate start',
    );
    return task;
  }

  // Build cron expression from poll interval seconds
  const pollSeconds = DEFAULT_POLL_SECONDS;
  // node-cron does not support seconds natively for arbitrary intervals;
  // use */30 pattern for 30s (or fallback to */1 minute for longer intervals).
  // For 30s: use two entries at */30 via the 6-field cron expression.
  const expression = `*/${pollSeconds} * * * * *`; // 6-field: seconds field

  task = cron.schedule(
    expression,
    () => {
      void runIngestionSweep().catch((err: unknown) => {
        logger.error(
          {
            action: 'ingestionWorker.unhandled',
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
          },
          'Unhandled sweep error',
        );
      });
    },
    { scheduled: true },
  );

  logger.info(
    { action: 'ingestionWorker.start', pollSeconds, expression },
    'Ingestion worker started',
  );

  return task;
}

export function stopIngestionWorker(): void {
  if (task) {
    task.stop();
    task = null;
    logger.info({ action: 'ingestionWorker.stop' }, 'Ingestion worker stopped');
  }
}
