/**
 * M16 / CR-H — Notification Retry Worker.
 *
 * node-cron-driven worker that picks up notification_dispatch_log rows
 * with status='pending_retry' and next_retry_at <= NOW() and retries
 * SMTP delivery.
 *
 * Pattern mirrors M11 ingestion.worker.ts + M14 score-recompute.worker.ts.
 *
 * S2-20: SYSTEM_ACTOR_ID = 0 — fn_ calls from this worker use actor 0.
 * Concurrency: p-limit(2) — at most 2 parallel retry attempts per batch.
 * Backoff: 1m → 5m → 30m → 2h → 8h (per CR-H-Q4 lock).
 *          NOTIFICATION_RETRY_BACKOFF_SCALE_SECONDS=true → 1s/5s/30s/120s/480s for E2E.
 * Mark status='final_failed' after 5th retry (fn_ handles this).
 *
 * Guards:
 *   - NODE_ENV=test → no-op
 *   - SMTP_RETRY_WORKER_ENABLED != 'true' → no-op
 */
import nodemailer from 'nodemailer';
import cron, { type ScheduledTask } from 'node-cron';
import pLimit from 'p-limit';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';

const RETRY_CONCURRENCY = 2;
const BATCH_SIZE = 25;
const SYSTEM_ACTOR_ID = 0;

let _cronTask: ScheduledTask | null = null;

// ----------------------------------------------------------------
// Types
// ----------------------------------------------------------------

interface RetryDueRow {
  id: number;
  channel: string;
  recipientAddress: string | null;
  subject: string | null;
  bodyRendered: string;
  retryCount: number;
  deliveryAttemptedAt: string;
  tenantId: string;
}

interface RetryDueResult {
  data: RetryDueRow[] | null;
}

// ----------------------------------------------------------------
// Backoff scale helper
// ----------------------------------------------------------------

function getBackoffSeconds(retryCount: number): number {
  const useSeconds = process.env['NOTIFICATION_RETRY_BACKOFF_SCALE_SECONDS'] === 'true';

  const minutes = [1, 5, 30, 120, 480]; // 1m / 5m / 30m / 2h / 8h
  const seconds = [1, 5, 30, 120, 480]; // E2E acceleration

  const scale = useSeconds ? seconds : minutes;
  const factor = useSeconds ? 1 : 60;
  const idx = Math.min(retryCount, scale.length - 1);
  return (scale[idx] ?? 1) * (useSeconds ? 1 : factor);
}

// ----------------------------------------------------------------
// SMTP helper (reuses env vars as fallback — real config from system_setting)
// ----------------------------------------------------------------

async function getSmtpTransporter(): Promise<nodemailer.Transporter> {
  // For the retry worker, pull SMTP config from env vars (system_setting is
  // not queried per-retry to avoid N extra DB calls in the hot path).
  return nodemailer.createTransport({
    host: process.env['SMTP_HOST'] ?? 'localhost',
    port: parseInt(process.env['SMTP_PORT'] ?? '587', 10),
    secure: process.env['SMTP_SECURE'] === 'true',
    auth:
      process.env['SMTP_USER'] && process.env['SMTP_PASSWORD']
        ? { user: process.env['SMTP_USER'], pass: process.env['SMTP_PASSWORD'] }
        : undefined,
    connectionTimeout: 10_000,
    greetingTimeout: 5_000,
    socketTimeout: 10_000,
  });
}

// ----------------------------------------------------------------
// Single retry attempt
// ----------------------------------------------------------------

async function retryNotification(row: RetryDueRow): Promise<void> {
  const startMs = Date.now();
  logger.info(
    {
      action: 'notificationRetryWorker.retryAttempt',
      notificationId: row.id,
      channel: row.channel,
      retryCount: row.retryCount,
    },
    'Retrying notification delivery',
  );

  // Only retry email channel — teams_capture and slack_capture are capture-only
  if (row.channel !== 'email') {
    logger.info(
      {
        action: 'notificationRetryWorker.captureChannelSkip',
        notificationId: row.id,
        channel: row.channel,
      },
      'Non-email channel — no retry needed, marking success',
    );
    // Mark as sent (capture channels are always "delivered" once logged)
    await db.callFunction<unknown>(
      'fn_notification_dispatch_update_retry_outcome',
      [row.id, true, null],
      { actorId: SYSTEM_ACTOR_ID, tenantId: row.tenantId },
    );
    return;
  }

  if (!row.recipientAddress) {
    logger.warn(
      {
        action: 'notificationRetryWorker.noRecipient',
        notificationId: row.id,
      },
      'No recipient address — marking final_failed',
    );
    await db.callFunction<unknown>(
      'fn_notification_dispatch_update_retry_outcome',
      [row.id, false, 'no_recipient_address'],
      { actorId: SYSTEM_ACTOR_ID, tenantId: row.tenantId },
    );
    return;
  }

  let success = false;
  let errorMsg: string | null = null;

  try {
    const transporter = await getSmtpTransporter();
    const fromAddress = process.env['SMTP_FROM'] ?? 'no-reply@musanad.local';
    const fromName = 'ADNOC Contracts Hub';

    await transporter.sendMail({
      from: `"${fromName}" <${fromAddress}>`,
      to: row.recipientAddress,
      subject: row.subject ?? 'ADNOC Advisory Notice',
      html: `<p>${row.bodyRendered.replace(/\n/g, '</p><p>')}</p>`,
      text: row.bodyRendered,
    });

    transporter.close();
    success = true;

    logger.info(
      {
        action: 'notificationRetryWorker.retrySuccess',
        notificationId: row.id,
        durationMs: Date.now() - startMs,
      },
      'Notification retry succeeded',
    );
  } catch (err) {
    errorMsg = err instanceof Error ? err.message.slice(0, 500) : String(err).slice(0, 500);
    logger.warn(
      {
        action: 'notificationRetryWorker.retryFailed',
        notificationId: row.id,
        retryCount: row.retryCount,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        durationMs: Date.now() - startMs,
      },
      'Notification retry attempt failed',
    );
  }

  // Update outcome — fn_ handles backoff calculation + final_failed promotion
  try {
    await db.callFunction<unknown>(
      'fn_notification_dispatch_update_retry_outcome',
      [row.id, success, errorMsg],
      { actorId: SYSTEM_ACTOR_ID, tenantId: row.tenantId },
    );
  } catch (updateErr) {
    logger.error(
      {
        action: 'notificationRetryWorker.outcomeUpdateFailed',
        notificationId: row.id,
        errorType: updateErr instanceof Error ? updateErr.name : 'UNKNOWN',
      },
      'Failed to update retry outcome',
    );
  }
}

// ----------------------------------------------------------------
// Batch processor
// ----------------------------------------------------------------

async function processBatch(): Promise<void> {
  logger.debug(
    { action: 'notificationRetryWorker.batchStart', batchSize: BATCH_SIZE },
    'Retry worker batch starting',
  );

  let result: RetryDueResult | null = null;
  try {
    result = await db.callFunction<RetryDueResult>(
      'fn_notification_dispatch_retry_due',
      [BATCH_SIZE],
      { actorId: SYSTEM_ACTOR_ID },
    );
  } catch (err) {
    logger.error(
      {
        action: 'notificationRetryWorker.fetchFailed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to fetch due retries',
    );
    return;
  }

  const rows = result?.data ?? [];
  if (rows.length === 0) {
    logger.debug(
      { action: 'notificationRetryWorker.batchEmpty' },
      'No pending retries due',
    );
    return;
  }

  logger.info(
    { action: 'notificationRetryWorker.batchProcessing', count: rows.length },
    'Processing notification retry batch',
  );

  const limit = pLimit(RETRY_CONCURRENCY);

  await Promise.all(
    rows.map((row) =>
      limit(() => retryNotification(row)).catch((err: unknown) => {
        logger.error(
          {
            action: 'notificationRetryWorker.pLimitError',
            notificationId: row.id,
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
          },
          'Unhandled error in p-limit retry wrapper',
        );
      }),
    ),
  );

  logger.info(
    { action: 'notificationRetryWorker.batchComplete', processed: rows.length },
    'Retry batch complete',
  );
}

// ----------------------------------------------------------------
// Public API: start / stop
// ----------------------------------------------------------------

/**
 * Start the notification retry worker.
 *
 * Guards:
 *   - NODE_ENV=test → no-op
 *   - SMTP_RETRY_WORKER_ENABLED != 'true' → no-op
 *
 * Cron schedule: every minute (* * * * *) — fn_ filters by next_retry_at <= NOW().
 */
export async function startNotificationRetryWorker(): Promise<void> {
  if (process.env['NODE_ENV'] === 'test') {
    logger.info(
      { action: 'notificationRetryWorker.start' },
      'Test mode — notification retry worker skipped',
    );
    return;
  }

  if (process.env['SMTP_RETRY_WORKER_ENABLED'] !== 'true') {
    logger.info(
      { action: 'notificationRetryWorker.start' },
      'SMTP_RETRY_WORKER_ENABLED is not true — skipped',
    );
    return;
  }

  if (_cronTask) {
    logger.warn(
      { action: 'notificationRetryWorker.alreadyRunning' },
      'Notification retry worker already started',
    );
    return;
  }

  // Schedule: every minute
  _cronTask = cron.schedule('* * * * *', () => {
    void processBatch().catch((err: unknown) => {
      logger.error(
        {
          action: 'notificationRetryWorker.cronError',
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'Unhandled error in retry worker cron',
      );
    });
  });

  logger.info(
    { action: 'notificationRetryWorker.started', schedule: '* * * * * (every minute)' },
    'Notification retry worker started',
  );

  process.once('SIGTERM', stopNotificationRetryWorker);
  process.once('SIGINT', stopNotificationRetryWorker);
}

/**
 * Stop the notification retry worker.
 */
export function stopNotificationRetryWorker(): void {
  if (_cronTask) {
    _cronTask.stop();
    _cronTask = null;
    logger.info(
      { action: 'notificationRetryWorker.stopped' },
      'Notification retry worker stopped',
    );
  }
}
