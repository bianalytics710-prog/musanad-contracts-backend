/**
 * M13 / CR-E — Correlation Evaluator Worker.
 *
 * Listens on PG NOTIFY 'osint_signal_inserted'.
 * For each new signal: load enabled rules from rule cache, call fn_rule_evaluate(signal_id).
 *
 * Performance target: 1000 signals × 50 rules in < 10s (HITL Q1).
 * Rule eval timeout: 5s per rule via DB fn_rule_evaluate timeout param (HITL Q1).
 * Conflict resolution: accept-both-correlations (HITL Q2) — handled in DB fn.
 *
 * Error handling per OD-2: writes correlation_evaluation_error row on:
 *   - Evaluation timeout
 *   - Predicate parse error
 *   - Template render error
 *
 * Test mode: NODE_ENV=test → no-op.
 * Guard: CORRELATION_EVALUATOR_WORKER_ENABLED=true required to start (default off in dev).
 */
import type { PoolClient } from 'pg';
import { pool } from '../database/config';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { getCachedRules } from '../services/rule-cache.service';

const SYSTEM_ACTOR_ID = 1;
const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
/** Rule evaluation timeout in milliseconds (HITL Q1: 5s) */
const RULE_EVAL_TIMEOUT_MS = 5_000;

let _notifyClient: PoolClient | null = null;

// ============================================================
// Signal processing
// ============================================================

/**
 * Process a single signal ID: evaluate all enabled rules via fn_rule_evaluate.
 * fn_rule_evaluate handles: matching, correlation persist, eval_error on timeout/failure.
 */
async function processSignal(signalId: number): Promise<void> {
  const rules = getCachedRules();
  if (rules.length === 0) {
    logger.debug({ action: 'correlationEvaluatorWorker.processSignal', signalId }, 'No enabled rules — skip');
    return;
  }

  logger.info(
    { action: 'correlationEvaluatorWorker.processSignal', signalId, ruleCount: rules.length },
    'Evaluating signal against rules',
  );

  const startMs = Date.now();
  let evaluatedCount = 0;
  let errorCount = 0;

  for (const rule of rules) {
    const ruleTimeoutMs = rule.evaluationTimeoutSecondsOverride != null
      ? rule.evaluationTimeoutSecondsOverride * 1000
      : RULE_EVAL_TIMEOUT_MS;

    try {
      // fn_rule_evaluate handles the full evaluation pipeline per DB design:
      // - Parses matchYaml/produceYaml from the DB (always fresh from DB not cache)
      // - Evaluates signal + all active contracts
      // - Persists correlation rows on match (accept-both per HITL Q2)
      // - Writes correlation_evaluation_error on timeout (OD-2)
      const evalPromise = db.callFunction<{ evaluated: boolean; correlationsCreated: number; errorWritten: boolean }>(
        'fn_rule_evaluate',
        [signalId, rule.id, ruleTimeoutMs, SYSTEM_ACTOR_ID, ADNOC_TENANT_ID],
        { actorId: SYSTEM_ACTOR_ID, tenantId: ADNOC_TENANT_ID },
      );

      // Enforce timeout at the BE layer as well (belt-and-suspenders per HITL Q1)
      const result = await Promise.race([
        evalPromise,
        new Promise<null>((_, reject) =>
          setTimeout(() => reject(new Error(`BE timeout after ${ruleTimeoutMs}ms`)), ruleTimeoutMs + 1000),
        ),
      ]);

      if (result) {
        evaluatedCount++;
        if (result.errorWritten) errorCount++;
      }
    } catch (err) {
      errorCount++;
      logger.warn(
        {
          action: 'correlationEvaluatorWorker.ruleEvalError',
          signalId,
          ruleId: rule.ruleId,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
          errorMessage: err instanceof Error ? err.message : String(err),
        },
        'Rule evaluation error (OD-2 — writing error record)',
      );

      // Write evaluation error record (OD-2) for any BE-layer failures
      try {
        await db.callFunction(
          'fn_rule_eval_error_record',
          [
            signalId,
            rule.ruleId,
            'other',
            null, // elapsedMs
            err instanceof Error ? err.message.slice(0, 500) : String(err),
            {},
            SYSTEM_ACTOR_ID,
            ADNOC_TENANT_ID,
          ],
          { actorId: SYSTEM_ACTOR_ID, tenantId: ADNOC_TENANT_ID },
        );
      } catch (writeErr) {
        logger.error(
          {
            action: 'correlationEvaluatorWorker.writeErrorRecord',
            signalId,
            ruleId: rule.ruleId,
            errorMessage: writeErr instanceof Error ? writeErr.message : String(writeErr),
          },
          'Failed to write evaluation error record',
        );
      }
    }
  }

  const durationMs = Date.now() - startMs;
  logger.info(
    {
      action: 'correlationEvaluatorWorker.processSignalComplete',
      signalId,
      ruleCount: rules.length,
      evaluatedCount,
      errorCount,
      durationMs,
    },
    'Signal evaluation complete',
  );
}

// ============================================================
// PG NOTIFY listener
// ============================================================

export async function startCorrelationEvaluatorWorker(): Promise<void> {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info({ action: 'correlationEvaluatorWorker.start' }, 'Test mode — correlation evaluator worker skipped');
    return;
  }

  if (process.env['CORRELATION_EVALUATOR_WORKER_ENABLED'] !== 'true') {
    logger.info({ action: 'correlationEvaluatorWorker.start' }, 'CORRELATION_EVALUATOR_WORKER_ENABLED is not true — skipped');
    return;
  }

  if (_notifyClient) return;

  try {
    const dbPool = pool();
    _notifyClient = await dbPool.connect();

    await _notifyClient.query("LISTEN osint_signal_inserted");

    _notifyClient.on('notification', async (msg) => {
      if (msg.channel === 'osint_signal_inserted') {
        let signalId: number;
        try {
          const payload = JSON.parse(msg.payload ?? '{}') as { signal_id?: number; id?: number };
          signalId = payload.signal_id ?? payload.id ?? 0;
        } catch {
          logger.warn(
            { action: 'correlationEvaluatorWorker.notification', payload: msg.payload },
            'Failed to parse osint_signal_inserted payload',
          );
          return;
        }

        if (!signalId || signalId <= 0) {
          logger.warn(
            { action: 'correlationEvaluatorWorker.notification', payload: msg.payload },
            'Invalid signal_id in notification payload',
          );
          return;
        }

        // Process asynchronously — don't block the notification handler
        processSignal(signalId).catch((err) => {
          logger.error(
            {
              action: 'correlationEvaluatorWorker.processSignalError',
              signalId,
              errorMessage: err instanceof Error ? err.message : String(err),
            },
            'Unhandled error processing signal',
          );
        });
      }
    });

    _notifyClient.on('error', (err) => {
      logger.error(
        { action: 'correlationEvaluatorWorker.listenerError', errorMessage: err.message },
        'PG NOTIFY connection error for osint_signal_inserted',
      );
      _notifyClient = null;
    });

    logger.info({ action: 'correlationEvaluatorWorker.start' }, 'Correlation evaluator worker started — listening on osint_signal_inserted');

    // Graceful shutdown
    process.once('SIGTERM', stopCorrelationEvaluatorWorker);
    process.once('SIGINT', stopCorrelationEvaluatorWorker);
  } catch (err) {
    logger.error(
      {
        action: 'correlationEvaluatorWorker.start',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Failed to start correlation evaluator worker',
    );
  }
}

export function stopCorrelationEvaluatorWorker(): void {
  if (_notifyClient) {
    void _notifyClient.query("UNLISTEN osint_signal_inserted").then(() => {
      _notifyClient?.release();
      _notifyClient = null;
    }).catch(() => {
      _notifyClient = null;
    });
    logger.info({ action: 'correlationEvaluatorWorker.stop' }, 'Correlation evaluator worker stopped');
  }
}
