/**
 * M19 / CR-K — Risk Case Auto-Create Worker.
 *
 * Listens on the existing PG NOTIFY channel 'correlation_inserted'
 * (emitted by fn_rule_evaluate per CR-F mig 172 — same channel the
 * score-recompute worker subscribes to). For each new signal that
 * produced correlations, this worker:
 *
 *   1. Connects to a dedicated pg client + LISTEN correlation_inserted.
 *   2. On notification: parses {tenantId, signalId, inserted} payload.
 *   3. Queries the correlation table for newly-inserted rows of this
 *      signal (last 60s) and, for each, calls
 *      fn_risk_case_auto_create_from_correlation(correlationId).
 *   4. fn is DEFINER + idempotent on dedupe_key 'correlation:<id>' so
 *      retries / concurrent worker races are safe.
 *
 * Guards:
 *   - NODE_ENV=test → no-op
 *   - RISK_CASE_AUTO_CREATE_WORKER_ENABLED != 'true' → no-op (default off)
 *
 * Pattern mirrors score-recompute.worker.ts.
 */
import type { PoolClient } from 'pg';
import pLimit from 'p-limit';
import { pool } from '../database/config';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';

const SYSTEM_ACTOR_ID = 0;
const CONCURRENCY = 2;

interface CorrelationInsertedPayload {
  tenantId?: string;
  signalId?: number;
  inserted?: number;
}

interface CorrelationRow {
  id: number;
}

let _notifyClient: PoolClient | null = null;

async function processCorrelationsForSignal(signalId: number, tenantId: string): Promise<void> {
  let correlationIds: number[] = [];
  try {
    const client = await pool().connect();
    try {
      // Look up correlations created for this signal in the last 5 minutes.
      // dedupe_key in fn_risk_case_auto_create guards against duplicate inserts.
      const result = await client.query<CorrelationRow>(
        `SELECT id FROM correlation
          WHERE signal_id = $1
            AND tenant_id = $2::UUID
            AND created_at > NOW() - INTERVAL '5 minutes'
          ORDER BY id DESC
          LIMIT 50`,
        [signalId, tenantId],
      );
      correlationIds = result.rows.map((r) => r.id);
    } finally {
      client.release();
    }
  } catch (err) {
    logger.error(
      {
        action: 'riskCaseAutoCreateWorker.fetchCorrelationsFailed',
        signalId,
        tenantId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to fetch correlations for auto-create',
    );
    return;
  }

  if (correlationIds.length === 0) {
    logger.debug(
      { action: 'riskCaseAutoCreateWorker.noCorrelations', signalId },
      'No correlations to auto-create for',
    );
    return;
  }

  const limit = pLimit(CONCURRENCY);
  await Promise.all(
    correlationIds.map((cid) =>
      limit(async () => {
        try {
          // DEFINER fn — no actor GUC needed; pass system actor for audit.
          const result = await db.callFunction<{ riskCaseId: number | null; wasNew: boolean }>(
            'fn_risk_case_auto_create_from_correlation',
            [cid],
            { actorId: SYSTEM_ACTOR_ID, tenantId },
          );
          if (result?.wasNew) {
            logger.info(
              {
                action: 'riskCaseAutoCreateWorker.created',
                correlationId: cid,
                riskCaseId: result.riskCaseId,
                tenantId,
              },
              'Auto-created risk case from correlation',
            );
          } else {
            logger.debug(
              {
                action: 'riskCaseAutoCreateWorker.dedupe',
                correlationId: cid,
                riskCaseId: result?.riskCaseId,
              },
              'Auto-create skipped (dedupe hit)',
            );
          }
        } catch (err) {
          logger.warn(
            {
              action: 'riskCaseAutoCreateWorker.autoCreateFailed',
              correlationId: cid,
              tenantId,
              errorType: err instanceof Error ? err.name : 'UNKNOWN',
              errorMessage: err instanceof Error ? err.message.slice(0, 200) : String(err).slice(0, 200),
            },
            'Auto-create from correlation failed (non-fatal)',
          );
        }
      }),
    ),
  );
}

export async function startRiskCaseAutoCreateWorker(): Promise<void> {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'riskCaseAutoCreateWorker.start' },
      'Test mode — risk case auto-create worker skipped',
    );
    return;
  }
  if (process.env['RISK_CASE_AUTO_CREATE_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'riskCaseAutoCreateWorker.start' },
      'RISK_CASE_AUTO_CREATE_WORKER_ENABLED is not true — skipped',
    );
    return;
  }
  if (_notifyClient) return;

  try {
    const dbPool = pool();
    _notifyClient = await dbPool.connect();
    await _notifyClient.query('LISTEN correlation_inserted');

    _notifyClient.on('notification', (msg) => {
      if (msg.channel !== 'correlation_inserted') return;
      let payload: CorrelationInsertedPayload;
      try {
        payload = JSON.parse(msg.payload ?? '{}') as CorrelationInsertedPayload;
      } catch {
        logger.warn(
          { action: 'riskCaseAutoCreateWorker.notification' },
          'Failed to parse correlation_inserted payload — skipping',
        );
        return;
      }

      const { signalId, tenantId, inserted } = payload;
      if (!signalId || signalId <= 0 || !tenantId || !inserted || inserted <= 0) {
        return;
      }

      void processCorrelationsForSignal(signalId, tenantId).catch((err: unknown) => {
        logger.error(
          {
            action: 'riskCaseAutoCreateWorker.processSignalError',
            signalId,
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
          },
          'Unhandled error processing signal for auto-create',
        );
      });
    });

    _notifyClient.on('error', (err) => {
      logger.error(
        { action: 'riskCaseAutoCreateWorker.listenerError', errorMessage: err.message },
        'PG NOTIFY connection error for correlation_inserted',
      );
      _notifyClient = null;
    });

    logger.info(
      { action: 'riskCaseAutoCreateWorker.started' },
      'Risk case auto-create worker started — listening on correlation_inserted',
    );

    process.once('SIGTERM', stopRiskCaseAutoCreateWorker);
    process.once('SIGINT', stopRiskCaseAutoCreateWorker);
  } catch (err) {
    logger.error(
      {
        action: 'riskCaseAutoCreateWorker.start',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to start risk case auto-create worker',
    );
  }
}

export function stopRiskCaseAutoCreateWorker(): void {
  if (_notifyClient) {
    void _notifyClient
      .query('UNLISTEN correlation_inserted')
      .then(() => {
        _notifyClient?.release();
        _notifyClient = null;
      })
      .catch(() => {
        _notifyClient = null;
      });
    logger.info(
      { action: 'riskCaseAutoCreateWorker.stopped' },
      'Risk case auto-create worker stopped',
    );
  }
}
