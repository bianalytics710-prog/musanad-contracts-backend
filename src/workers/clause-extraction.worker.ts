/**
 * M12 / CR-D — Clause Extraction Worker.
 *
 * Cadence: every 30s (* /30 * * * * pattern — same as M11 ingestion.worker).
 * Concurrency: p-limit(2) — at most 2 parallel extractions per tick.
 *
 * Per tick:
 *   1. SELECT contract_version rows where ingestion_status='complete' AND
 *      no pending/in-progress extraction run exists.
 *   2. For each: call fn_clause_extraction_request to enqueue, then run
 *      clause-extraction.service.extractClausesForVersion.
 *   3. On completion: mark extraction run complete.
 *   4. On error: mark extraction run failed.
 *
 * Test mode: NODE_ENV=test → no-op.
 * Guard: CLAUSE_EXTRACTION_WORKER_ENABLED=true required to start (default off in dev).
 */
import cron, { type ScheduledTask } from 'node-cron';
import pLimit from 'p-limit';
import { pool } from '../database/config';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { extractClausesForVersion } from '../services/clause-extraction.service';

const SYSTEM_ACTOR_ID = 1;
const DEFAULT_CONCURRENCY = 2;

let task: ScheduledTask | null = null;

interface PendingExtractionRow {
  contract_version_id: number;
  extracted_text_uri: string;
  contract_id: number;
}

/**
 * Fetch contract_version rows ready for clause extraction:
 *   - ingestion_status = 'complete'
 *   - extracted_text_uri IS NOT NULL
 *   - No existing clause_extraction_run row (or fn_clause_extraction_request handles idempotency)
 */
async function fetchPendingExtractions(): Promise<PendingExtractionRow[]> {
  const client = await pool().connect();
  try {
    const res = await client.query<PendingExtractionRow>(
      `SELECT cv.id AS contract_version_id,
              cv.extracted_text_uri,
              cv.contract_id
         FROM contract_version cv
        WHERE cv.ingestion_status = 'complete'
          AND cv.extracted_text_uri IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
              FROM contract_clause_extracted cce
             WHERE cce.contract_version_id = cv.id
               AND cce.is_active = TRUE
            LIMIT 1
          )
        ORDER BY cv.id ASC
        LIMIT $1`,
      [DEFAULT_CONCURRENCY * 2],
    );
    return res.rows;
  } finally {
    client.release();
  }
}

/** ADNOC single-tenant sentinel — same as rls.middleware fallback. */
const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

async function processTick(): Promise<void> {
  // CR-V: module-enabled guard — skip if 'clauses' module is disabled for the default tenant.
  // Clause extraction uses the single-tenant ADNOC UUID (multi-tenant: extend per-row).
  try {
    const enabled = await db.callFunction<boolean>(
      'fn_module_enabled',
      [ADNOC_TENANT_ID, 'clauses'],
      { actorId: SYSTEM_ACTOR_ID, tenantId: ADNOC_TENANT_ID },
    );
    if (!enabled) {
      logger.info({ action: 'clauseExtractionWorker.moduleDisabled', moduleKey: 'clauses' },
        'module disabled, worker tick skipped');
      return;
    }
  } catch (guardErr) {
    logger.warn({ action: 'clauseExtractionWorker.moduleGuardError',
      errorType: guardErr instanceof Error ? guardErr.name : 'UNKNOWN' },
      'module guard check failed — continuing (fail-open)');
  }

  let rows: PendingExtractionRow[];
  try {
    rows = await fetchPendingExtractions();
  } catch (err) {
    logger.error(
      {
        action: 'clauseExtractionWorker.tick',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Failed to fetch pending extraction rows',
    );
    return;
  }

  if (rows.length === 0) return;

  logger.info({ action: 'clauseExtractionWorker.tick', pendingCount: rows.length }, 'Processing pending clause extractions');

  const limit = pLimit(DEFAULT_CONCURRENCY);

  await Promise.allSettled(
    rows.map((row) =>
      limit(async () => {
        const { contract_version_id, extracted_text_uri } = row;
        try {
          await extractClausesForVersion(contract_version_id, extracted_text_uri, SYSTEM_ACTOR_ID);
        } catch (err) {
          logger.error(
            {
              action: 'clauseExtractionWorker.processRow',
              contractVersionId: contract_version_id,
              errorType: err instanceof Error ? err.name : 'UNKNOWN',
              errorMessage: err instanceof Error ? err.message : String(err),
            },
            'Clause extraction failed for contract version',
          );
        }
      }),
    ),
  );
}

export function startClauseExtractionWorker(): void {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info({ action: 'clauseExtractionWorker.start' }, 'Test mode — clause extraction worker skipped');
    return;
  }

  if (process.env['CLAUSE_EXTRACTION_WORKER_ENABLED'] !== 'true') {
    logger.info({ action: 'clauseExtractionWorker.start' }, 'CLAUSE_EXTRACTION_WORKER_ENABLED is not true — skipped');
    return;
  }

  if (task) return; // already started

  task = cron.schedule('*/30 * * * * *', async () => {
    await processTick();
  });

  logger.info({ action: 'clauseExtractionWorker.start' }, 'Clause extraction worker started (*/30s)');

  // Graceful shutdown
  process.once('SIGTERM', stopClauseExtractionWorker);
  process.once('SIGINT', stopClauseExtractionWorker);
}

export function stopClauseExtractionWorker(): void {
  if (task) {
    task.stop();
    task = null;
    logger.info({ action: 'clauseExtractionWorker.stop' }, 'Clause extraction worker stopped');
  }
}
