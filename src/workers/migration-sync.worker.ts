/**
 * M22 / CR-MIG-DRIVE — Migration sync worker.
 *
 * Cadence: every 10s (per brief NFR).
 * Concurrency: p-limit(2) — at most 2 batches processed per tick.
 *
 * Guard: MIGRATION_SYNC_WORKER_ENABLED=true required to start.
 * Test mode: NODE_ENV=test → no-op.
 */
import cron, { type ScheduledTask } from 'node-cron';
import pLimit from 'p-limit';
import { pool } from '../database/config';
import { logger } from '../utils/logger.util';
import { processBatch } from '../services/migration-orchestrator.service';

const POLL_SECONDS = 10;
const CONCURRENCY = 2;
const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

let task: ScheduledTask | null = null;

interface PendingBatchRow {
  id: number;
  tenant_id: string;
}

async function fetchQueuedBatches(): Promise<PendingBatchRow[]> {
  const r = await pool().query<PendingBatchRow>(
    `SELECT id, tenant_id::text AS tenant_id
       FROM migration_batch
      WHERE status = 'queued'
      ORDER BY started_at ASC
      LIMIT $1`,
    [CONCURRENCY * 2],
  );
  return r.rows;
}

export async function runMigrationSweep(): Promise<{ processed: number; failed: number }> {
  const startedAt = Date.now();
  const stats = { processed: 0, failed: 0 };
  const batches = await fetchQueuedBatches();
  if (batches.length === 0) return stats;
  const limit = pLimit(CONCURRENCY);
  await Promise.all(
    batches.map((b) =>
      limit(async () => {
        try {
          await processBatch({ batchId: b.id, tenantId: b.tenant_id || ADNOC_TENANT_ID });
          stats.processed += 1;
        } catch (err) {
          stats.failed += 1;
          logger.error(
            {
              action: 'migrationSyncWorker.batch.failed',
              batchId: b.id,
              errorType: err instanceof Error ? err.name : 'UNKNOWN',
            },
            'Migration batch fatal in worker',
          );
        }
      }),
    ),
  );
  logger.info(
    { action: 'migrationSyncWorker.sweep', ...stats, durationMs: Date.now() - startedAt },
    'Migration sweep complete',
  );
  return stats;
}

export function startMigrationSyncWorker(): ScheduledTask | null {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info({ action: 'migrationSyncWorker.skip', reason: 'NODE_ENV=test' });
    return null;
  }
  if (process.env['MIGRATION_SYNC_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'migrationSyncWorker.skip', reason: 'MIGRATION_SYNC_WORKER_ENABLED!=true' },
      'Migration sync worker not enabled',
    );
    return null;
  }
  if (task) return task;
  const expression = `*/${POLL_SECONDS} * * * * *`;
  task = cron.schedule(
    expression,
    () => {
      void runMigrationSweep().catch((err: unknown) => {
        logger.error(
          {
            action: 'migrationSyncWorker.unhandled',
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
          },
          'Unhandled migration sweep error',
        );
      });
    },
    { scheduled: true },
  );
  logger.info(
    { action: 'migrationSyncWorker.start', pollSeconds: POLL_SECONDS, expression },
    'Migration sync worker started',
  );
  return task;
}

export function stopMigrationSyncWorker(): void {
  if (task) {
    task.stop();
    task = null;
    logger.info({ action: 'migrationSyncWorker.stop' });
  }
}
