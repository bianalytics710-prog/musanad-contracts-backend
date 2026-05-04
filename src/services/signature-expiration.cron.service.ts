/**
 * Signature-invitation expiration cron driver (M3 / S9).
 *
 * Calls `fn_signature_invitation_expire_due(p_batch_size)` in a loop until
 * the returned `expiredInvitations` count is less than the batch size. The
 * fn_ is SECURITY DEFINER + GRANT EXECUTE TO neondb_owner ONLY (REVOKED FROM
 * PUBLIC) — the BE pool's connection role (neondb_owner via DATABASE_URL)
 * is what authorises the call.
 *
 * S2-20 SYSTEM_ACTOR sentinel: this driver MUST set
 * `app.current_user_id = '0'` before invoking the fn so that
 * fn_contract_activity_create coerces the actor to NULL via the canonical
 * M2 031 path. db.callFunction({ actorId }) does this via SET LOCAL inside
 * the same transaction the fn runs in.
 *
 * Default schedule: every 15 minutes (CLAUDE.md / DN-13). Override via
 * SIGNATURE_EXPIRATION_INTERVAL_CRON env var. Disabled in NODE_ENV=test
 * (the smoke harness short-circuits like the M2 escalation driver).
 *
 * Mirrors src/services/approval-escalation.cron.service.ts (M2 / S9).
 */
import cron, { type ScheduledTask } from 'node-cron';
import { logger } from '../utils/logger.util';
import * as signatureService from './signature.service';

const DEFAULT_CRON = '*/15 * * * *';
const BATCH_SIZE = 100;
/** Fail-safe: never let one sweep loop more than this many batches. */
const MAX_BATCHES_PER_SWEEP = 50;

/**
 * S2-20 sentinel — fn_contract_activity_create coerces actor IDs of NULL or 0
 * to NULL on the activity row. We pass 0 so db.callFunction sets the GUC
 * (Number.isFinite(0) === true) — passing undefined would skip the SET LOCAL
 * and the activity insert path's coercion would never see the sentinel.
 */
const SYSTEM_ACTOR_ID = 0;

let task: ScheduledTask | null = null;

interface SweepStats {
  batches: number;
  totalExpired: number;
  totalHalted: number;
  durationMs: number;
}

/**
 * One expiration sweep. Loops until the fn_ returns fewer expirations than
 * BATCH_SIZE (drained) OR MAX_BATCHES_PER_SWEEP is reached (safety cap).
 *
 * Exposed for tests + startup self-test.
 */
export const runExpirationSweep = async (): Promise<SweepStats> => {
  const startTime = Date.now();
  let batches = 0;
  let totalExpired = 0;
  let totalHalted = 0;

  for (;;) {
    if (batches >= MAX_BATCHES_PER_SWEEP) {
      logger.warn(
        {
          action: 'signatureExpirationCron.batch_cap_reached',
          batches,
          totalExpired,
        },
        'Hit MAX_BATCHES_PER_SWEEP — leaving remaining expirations for the next sweep',
      );
      break;
    }
    let result;
    try {
      result = await signatureService.expireInvitationsBatch(SYSTEM_ACTOR_ID, BATCH_SIZE);
    } catch (err) {
      logger.error(
        {
          action: 'signatureExpirationCron.batch_failed',
          batchIndex: batches,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
          message: err instanceof Error ? err.message : String(err),
        },
        'Expiration batch failed (non-fatal)',
      );
      // Per memory feedback_db_impl_report_dont_fix.md / M2 031 lesson:
      // do NOT silently swallow FK violations. We log and break out so
      // operator visibility is preserved; the next cron tick retries.
      break;
    }

    if (!result) {
      // fn_ returned NULL — should not happen under happy path. Treat as
      // drained.
      break;
    }

    batches += 1;
    totalExpired += result.expiredInvitations;
    totalHalted += result.contractsHalted;

    if (result.expiredInvitations < BATCH_SIZE) {
      // Drained — fewer expirations than the batch we asked for means
      // there is nothing else due right now.
      break;
    }
  }

  const stats: SweepStats = {
    batches,
    totalExpired,
    totalHalted,
    durationMs: Date.now() - startTime,
  };

  if (totalExpired === 0) {
    logger.debug(
      { action: 'signatureExpirationCron.sweep', ...stats },
      'No invitations due for expiration',
    );
  } else {
    logger.info(
      { action: 'signatureExpirationCron.sweep', ...stats },
      'Signature expiration sweep complete',
    );
  }

  return stats;
};

/**
 * Start the cron driver. Idempotent. NODE_ENV=test short-circuits.
 */
export const startSignatureExpirationCron = (): ScheduledTask | null => {
  if (process.env.NODE_ENV === 'test') {
    logger.info(
      { action: 'signatureExpirationCron.skip', reason: 'NODE_ENV=test' },
      'Signature expiration cron disabled in test env',
    );
    return null;
  }
  if (task) {
    logger.warn(
      { action: 'signatureExpirationCron.start' },
      'Signature expiration cron already running — skipping duplicate start',
    );
    return task;
  }
  const expression = process.env.SIGNATURE_EXPIRATION_INTERVAL_CRON ?? DEFAULT_CRON;
  if (!cron.validate(expression)) {
    logger.error(
      { action: 'signatureExpirationCron.invalid_expression', expression },
      'SIGNATURE_EXPIRATION_INTERVAL_CRON is not a valid cron expression — driver NOT started',
    );
    return null;
  }
  task = cron.schedule(
    expression,
    () => {
      void runExpirationSweep().catch((err) => {
        logger.error(
          {
            action: 'signatureExpirationCron.unhandled',
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
            message: err instanceof Error ? err.message : String(err),
          },
          'Unhandled expiration sweep error',
        );
      });
    },
    { scheduled: true },
  );
  logger.info(
    { action: 'signatureExpirationCron.start', expression },
    'Signature expiration cron started',
  );
  return task;
};

/** Stop the cron driver. Used by graceful shutdown + tests. */
export const stopSignatureExpirationCron = (): void => {
  if (task) {
    task.stop();
    task = null;
    logger.info(
      { action: 'signatureExpirationCron.stop' },
      'Signature expiration cron stopped',
    );
  }
};
