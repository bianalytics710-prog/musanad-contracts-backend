/**
 * Express server entry point.
 *
 * Critical import order (per skill-logging-patterns.md §2):
 *   1. dotenv (loads .env.local before validateEnv reads process.env)
 *   2. validateEnv() — fails fast if any required var is missing
 *   3. telemetry.util — must be imported BEFORE pg/express so OTel
 *      auto-instrumentations attach
 *   4. logger.util
 *   5. everything else
 *
 * Middleware stack (request order):
 *   helmet → cors → compression → json body parser → correlation
 *   → routes → 404 handler → error handler
 *
 * Env loading strategy (belt + suspenders):
 *   - npm scripts pass `-r dotenv/config dotenv_config_path=...` so env is
 *     loaded BEFORE this module evaluates.
 *   - As a defensive fallback (when invoked outside npm — e.g., directly
 *     via `node`/`tsx` or an IDE debugger), we also load dotenv here.
 *     `override: false` ensures values already in process.env (set by the
 *     OS, k8s, Docker, or the preload step above) win.
 */
import dotenv from 'dotenv';
import path from 'node:path';
const _envFile = process.env.NODE_ENV === 'production' ? '.env' : '.env.local';
dotenv.config({ path: path.resolve(process.cwd(), _envFile), override: false });
dotenv.config({ override: false }); // fallback to default .env if present
import { validateEnv } from './utils/env-validation.util';
const _env = validateEnv();

// MUST come BEFORE any module that imports pg / express directly so the
// OTel auto-instrumentations attach.
import './utils/telemetry.util';

import express from 'express';
import type { Request, Response, NextFunction } from 'express';
import helmet from 'helmet';
import cors from 'cors';
import compression from 'compression';
import { logger } from './utils/logger.util';
import { correlationMiddleware } from './middleware/correlation.middleware';
import { errorMiddleware } from './middleware/error.middleware';
import { NotFoundError } from './utils/errors.util';
import topRouter from './routes';
import { closePool, pool } from './database/config';
import { telemetry } from './utils/telemetry.util';
import { closeBrowser as closePuppeteerBrowser } from './services/export/puppeteer-pool.service';
import {
  startApprovalEscalationCron,
  stopApprovalEscalationCron,
} from './services/approval-escalation.cron.service';
import {
  startSignatureExpirationCron,
  stopSignatureExpirationCron,
} from './services/signature-expiration.cron.service';
import {
  startAiInsightEvictionCron,
  stopAiInsightEvictionCron,
} from './services/ai-insight-eviction.cron.service';
// M7 — OSINT source-fetch + health workers (CR-A — S7 / S8)
import {
  startSourceFetchWorker,
  stopSourceFetchWorker,
} from './workers/source-fetch.worker';
import {
  startSourceHealthWorker,
  stopSourceHealthWorker,
} from './workers/source-health.worker';
// M11 (CR-D0) — Document Ingestion worker
import {
  startIngestionWorker,
  stopIngestionWorker,
} from './workers/ingestion.worker';
// M12 (CR-D) — Clause Extraction worker
import {
  startClauseExtractionWorker,
  stopClauseExtractionWorker,
} from './workers/clause-extraction.worker';
// M13 (CR-E) — Correlation Evaluator worker + Rule Cache listener
import {
  startCorrelationEvaluatorWorker,
  stopCorrelationEvaluatorWorker,
} from './workers/correlation-evaluator.worker';
import {
  startRuleCacheListener,
  stopRuleCacheListener,
} from './services/rule-cache.service';
// M14 (CR-F) — Score Recompute worker (PG LISTEN correlation_inserted + daily cron)
import {
  startScoreRecomputeWorker,
  stopScoreRecomputeWorker,
} from './workers/score-recompute.worker';
// M16 (CR-H) — Notification Retry worker (node-cron every-minute backoff retry)
import {
  startNotificationRetryWorker,
  stopNotificationRetryWorker,
} from './workers/notification-retry.worker';
// Phase C — Risk Case auto-dismiss (nightly stale-cleanup)
import {
  startRiskCaseAutoDismissWorker,
  stopRiskCaseAutoDismissWorker,
} from './workers/risk-case-auto-dismiss.worker';
// M22 (CR-MIG-DRIVE) — Migration sync worker
import {
  startMigrationSyncWorker,
  stopMigrationSyncWorker,
} from './workers/migration-sync.worker';
// M19 (CR-K) — Risk Case Escalation worker (node-cron every-5-min)
import {
  startRiskCaseEscalationWorker,
  stopRiskCaseEscalationWorker,
} from './workers/risk-case-escalation.worker';
// M19 (CR-K) — Risk Case Auto-Create worker (PG LISTEN correlation_inserted)
import {
  startRiskCaseAutoCreateWorker,
  stopRiskCaseAutoCreateWorker,
} from './workers/risk-case-auto-create.worker';
// M20 (CR-L) — Report Run worker (node-cron every 10s)
import {
  startReportRunWorker,
  stopReportRunWorker,
} from './workers/report-run.worker';
// M20 (CR-L) — Report Scheduler service (refreshes scheduled-template cron tasks)
import {
  startReportScheduler,
  stopReportScheduler,
} from './services/report-scheduler.service';
// M21 (CR-O) — Margin Recompute worker (PG LISTEN margin_recompute_requested + daily cron)
import {
  startMarginRecomputeWorker,
  stopMarginRecomputeWorker,
} from './workers/margin-recompute.worker';
// Obligation SLA Escalation worker (mig 500 — daily cron)
import {
  startObligationSlaEscalationWorker,
  stopObligationSlaEscalationWorker,
} from './workers/obligation-sla-escalation.worker';
// Phase D (mig 647, 2026-06-13) — Risk Triage Auto-Escalate worker (daily cron)
import {
  startRiskTriageAutoEscalateWorker,
  stopRiskTriageAutoEscalateWorker,
} from './workers/risk-triage-auto-escalate.worker';

const app = express();

// --- Trust proxy (CRX-6) ---
// Required so req.ip reflects the real client IP behind a single reverse
// proxy (e.g. Azure Front Door / Cloudflare). The rate limiter relies on
// req.ip / X-Forwarded-For. Adjust the hop count if this service is
// deployed behind multiple proxies; `true` (trust all) is unsafe because
// it lets an attacker spoof X-Forwarded-For from outside.
//
// Scaling note: src/middleware/rate-limit.middleware.ts uses
// RateLimiterMemory, which is per-process and therefore leaks quota across
// replicas. Before scaling beyond 1 replica, swap to RateLimiterRedis
// (rate-limiter-flexible already supports it) — see rate-limit.middleware.ts
// header comment.
app.set('trust proxy', 1);

// --- helmet (security headers) ---
app.use(
  helmet({
    contentSecurityPolicy: false, // API; CSP is a frontend concern
    crossOriginEmbedderPolicy: false,
    crossOriginResourcePolicy: { policy: 'cross-origin' },
  }),
);

// --- CORS allowlist from CORS_ORIGIN env (comma-separated) ---
const corsOrigins = _env.CORS_ORIGIN.split(',').map((s) => s.trim()).filter(Boolean);
app.use(
  cors({
    origin: (origin, cb) => {
      if (!origin) return cb(null, true); // same-origin / curl
      if (corsOrigins.includes(origin) || corsOrigins.includes('*')) {
        return cb(null, true);
      }
      return cb(null, false);
    },
    credentials: true,
    exposedHeaders: [_env.REQUEST_ID_HEADER],
  }),
);

// --- Compression ---
app.use(compression());

// --- JSON body parser with size limit ---
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false, limit: '1mb' }));

// --- Correlation ID + child logger ---
app.use(correlationMiddleware);

// --- Routes ---
app.use('/api', topRouter);

// 404
app.use((req: Request, _res: Response, next: NextFunction) => {
  next(new NotFoundError(`Route not found: ${req.method} ${req.path}`));
});

// Error handler — last
app.use(errorMiddleware);

// --- Startup ---
const port = _env.PORT;
const server = app.listen(port, () => {
  logger.info(
    {
      action: 'server.startup',
      port,
      nodeEnv: _env.NODE_ENV,
      service: _env.SERVICE_NAME,
      aiProvider: _env.AI_PROVIDER,
      uaePassProvider: _env.UAE_PASS_PROVIDER,
    },
    `OqoodAI Contracts backend listening on port ${port}`,
  );

  // M2 / S9 — start approval-escalation cron driver. The driver is a no-op
  // in NODE_ENV=test (smoke harness owns scheduling). On boot the driver
  // simply schedules the cron task; the first sweep fires per the cron
  // expression (default every 15 minutes).
  startApprovalEscalationCron();

  // M3 / S9 — start signature-expiration cron driver (mirrors approval
  // escalation pattern; per DN-13 + cron driver contract). No-op in
  // NODE_ENV=test. SYSTEM_ACTOR sentinel sets app.current_user_id='0'
  // before each fn_signature_invitation_expire_due call.
  startSignatureExpirationCron();

  // M4 / S8 — start AI insight cache eviction cron (3rd cron driver in the
  // codebase). No-op in NODE_ENV=test. SYSTEM_ACTOR sentinel sets
  // app.current_user_id='0' before each fn_ai_insight_evict_expired call.
  startAiInsightEvictionCron();

  // M7 / S7 + S8 — OSINT source-fetch + health workers. Both no-op in
  // NODE_ENV=test AND require SOURCE_FETCH_WORKER_ENABLED / SOURCE_HEALTH_
  // WORKER_ENABLED=true (default false in CR-A so dev boots stay quiet).
  startSourceFetchWorker();
  startSourceHealthWorker();

  // M11 (CR-D0) — Document Ingestion worker. No-op in NODE_ENV=test AND
  // requires INGESTION_WORKER_ENABLED=true (default off so dev boots stay
  // quiet). Runs every 30s, processes up to 2 concurrent jobs per tick.
  startIngestionWorker();

  // M12 (CR-D) — Clause Extraction worker. No-op in NODE_ENV=test AND
  // requires CLAUSE_EXTRACTION_WORKER_ENABLED=true (default off in dev).
  // Runs every 30s, p-limit(2) concurrency.
  startClauseExtractionWorker();

  // M13 (CR-E) — Rule Cache listener + Correlation Evaluator worker.
  // Rule cache: startRuleCacheListener() is async — fire and forget on startup.
  //   Registers LISTEN correlation_rule_changed + performs initial rule load.
  //   No-op guard: test mode / missing env var handled inside the service.
  // Correlation evaluator: LISTEN osint_signal_inserted. No-op in test AND
  //   requires CORRELATION_EVALUATOR_WORKER_ENABLED=true (default off in dev).
  void startRuleCacheListener();
  void startCorrelationEvaluatorWorker();

  // M14 (CR-F) — Score Recompute worker.
  // PG LISTEN correlation_inserted: recompute risk scores when new correlations
  //   are inserted by fn_rule_evaluate. No-op in test AND requires
  //   SCORE_RECOMPUTE_WORKER_ENABLED=true (default off in dev).
  // Daily cron at 00:30 UTC: full recompute via fn_score_recompute_for_weight_change
  //   with SYSTEM_ACTOR_ID=0 sentinel (S2-20).
  void startScoreRecomputeWorker();

  // M16 (CR-H) — Notification Retry worker.
  // Runs every minute via node-cron. Picks up pending_retry rows from
  //   notification_dispatch_log where next_retry_at <= now(). No-op in test
  //   AND requires SMTP_RETRY_WORKER_ENABLED=true (default off in dev).
  void startNotificationRetryWorker();

  // Phase C — Risk Case auto-dismiss worker. Nightly 02:30 UTC.
  // Closes stale (>14d) open/in_review cases that nobody self-claimed.
  // No-op in NODE_ENV=test; disable via RISK_CASE_AUTO_DISMISS_ENABLED=false.
  startRiskCaseAutoDismissWorker();

  // M22 (CR-MIG-DRIVE) — Migration sync worker (every 10s).
  // Disabled by default unless MIGRATION_SYNC_WORKER_ENABLED=true.
  startMigrationSyncWorker();

  // M19 (CR-K) — Risk Case Escalation worker.
  // Runs every 5 min via node-cron. fn_risk_case_escalation_check enumerates
  //   cross-tenant; worker sets per-row tenant GUC before fn_risk_case_escalate.
  // No-op in test AND requires RISK_CASE_ESCALATION_WORKER_ENABLED=true.
  startRiskCaseEscalationWorker();

  // Phase D (mig 647, 2026-06-13) — Risk Triage Auto-Escalate worker.
  // Daily at 06:00 UTC. fn_risk_triage_auto_escalate marks Tier-2 cases that
  // have been unactioned past tier2AutoEscalateDays + writes a
  // tier2_auto_escalated risk_case_event row. No-op in test AND requires
  // RISK_TRIAGE_AUTO_ESCALATE_WORKER_ENABLED=true.
  startRiskTriageAutoEscalateWorker();

  // M19 (CR-K) — Risk Case Auto-Create worker.
  // PG LISTEN 'correlation_inserted' (shared channel from CR-F mig 172).
  // Calls fn_risk_case_auto_create_from_correlation for each new correlation;
  // fn is DEFINER + idempotent on dedupe_key. No-op in test AND requires
  // RISK_CASE_AUTO_CREATE_WORKER_ENABLED=true (default off in dev).
  void startRiskCaseAutoCreateWorker();

  // M20 (CR-L) — Report Run worker.
  // Runs every 10s via node-cron. fn_report_run_pending_get picks up to 5
  // pending rows; renders PDF/XLSX via report-renderer; uploads to Supabase;
  // calls fn_report_run_complete. No-op in test AND requires
  // REPORT_RUN_WORKER_ENABLED=true (default off in dev).
  startReportRunWorker();

  // M20 (CR-L) — Report Scheduler.
  // Refreshes node-cron tasks for is_scheduled templates every 5 min.
  // Each scheduled task enqueues a report_run with triggered_by='scheduled'.
  // No-op in test AND requires REPORT_SCHEDULER_ENABLED=true.
  startReportScheduler();

  // M21 (CR-O) — Margin Recompute worker.
  // PG LISTEN margin_recompute_requested: log/verify MV after price-change recomputes.
  // Daily sentinel cron at 01:00 UTC: fn_margin_aggregate probe.
  // No-op in test AND requires MARGIN_RECOMPUTE_WORKER_ENABLED=true (default off).
  // Demo path is the synchronous POST /price-benchmarks/recompute — this worker
  // is the production async wiring.
  void startMarginRecomputeWorker();

  // Obligation SLA Escalation worker (mig 500).
  // Daily at 05:00 UTC. fn_obligation_sla_check enumerates {obligation,tier}
  // pairs that crossed T+3/7/14/21d; fn_obligation_sla_dispatch fans
  // in-app notifications + writes obligation_escalation_event.
  // No-op in test AND requires OBLIGATION_SLA_WORKER_ENABLED=true (default off).
  startObligationSlaEscalationWorker();
});

// --- Graceful shutdown ---
const shutdown = async (signal: string): Promise<void> => {
  logger.info({ action: 'server.shutdown', signal }, 'Shutdown initiated');
  try {
    // Stop the approval-escalation cron driver before draining requests so
    // no new sweep starts mid-shutdown.
    stopApprovalEscalationCron();
    // M3 — stop signature-expiration cron driver as well.
    stopSignatureExpirationCron();
    // M4 — stop AI insight eviction cron driver.
    stopAiInsightEvictionCron();
    // M7 — stop OSINT source-fetch + source-health workers.
    stopSourceFetchWorker();
    stopSourceHealthWorker();
    // M11 (CR-D0) — stop ingestion worker.
    stopIngestionWorker();
    // M22 — stop migration sync worker.
    stopMigrationSyncWorker();
    // M12 (CR-D) — stop clause extraction worker.
    stopClauseExtractionWorker();
    // M13 (CR-E) — stop correlation evaluator worker + rule cache listener.
    stopCorrelationEvaluatorWorker();
    await stopRuleCacheListener();
    // M14 (CR-F) — stop score recompute worker (PG LISTEN + cron).
    stopScoreRecomputeWorker();
    // M16 (CR-H) — stop notification retry worker.
    stopNotificationRetryWorker();
    stopRiskCaseAutoDismissWorker();
    // M19 (CR-K) — stop risk case escalation + auto-create workers.
    stopRiskCaseEscalationWorker();
    stopRiskCaseAutoCreateWorker();
    // Phase D (mig 647) — stop risk triage auto-escalate worker.
    stopRiskTriageAutoEscalateWorker();
    // M20 (CR-L) — stop report run worker + scheduler.
    stopReportRunWorker();
    stopReportScheduler();
    // M21 (CR-O) — stop margin recompute worker (PG LISTEN + cron).
    stopMarginRecomputeWorker();
    // Obligation SLA escalation worker (mig 500).
    stopObligationSlaEscalationWorker();

    await new Promise<void>((resolve, reject) => {
      server.close((err) => (err ? reject(err) : resolve()));
    });
    logger.info({ action: 'server.requests_drained' }, 'Active requests drained');

    await closePool();
    logger.info({ action: 'server.pool_closed' }, 'pg pool closed');

    // Codex BE-M1b-003: close shared Puppeteer browser if it was started.
    await closePuppeteerBrowser();
    logger.info({ action: 'server.puppeteer_closed' }, 'Puppeteer browser closed');

    await telemetry.shutdown();
    logger.info({ action: 'server.telemetry_closed' }, 'Telemetry shut down');

    logger.info({ action: 'server.shutdown_complete' }, 'Shutdown complete');
    process.exit(0);
  } catch (err) {
    logger.error(
      {
        action: 'server.shutdown_error',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Shutdown error',
    );
    process.exit(1);
  }
};

process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));

process.on('unhandledRejection', (reason: unknown) => {
  logger.error(
    {
      action: 'process.unhandledRejection',
      message: reason instanceof Error ? reason.message : String(reason),
    },
    'Unhandled promise rejection',
  );
});

process.on('uncaughtException', (err: Error) => {
  // M22 — Tesseract.js / Leptonica throws asynchronous Lepton errors when
  // it can't parse a particular PDF (scanned with unusual encoding,
  // corrupted, etc.). These bubble up as uncaughtException with messages
  // like "Error attempting to read image" / "Pdf reading is not supported".
  // The per-file failure is already recorded in migration_record by the
  // orchestrator's try/catch — we MUST NOT take the whole BE down for one
  // unparsable PDF, otherwise a single bad file halts an entire batch and
  // we lose the rest of the run.
  const msg = err.message || '';
  if (
    /attempting to read image|Pdf reading is not supported|pixRead|pixReadStream|tesseract|leptonica/i.test(msg)
  ) {
    logger.warn(
      { action: 'process.uncaughtException.tolerated', errorType: err.name, message: msg },
      'Tolerating Tesseract/Leptonica async failure — per-file error already recorded',
    );
    return;
  }
  logger.fatal(
    { action: 'process.uncaughtException', errorType: err.name, message: err.message },
    'Uncaught exception — exiting',
  );
  // Crash explicitly — do NOT keep running
  void shutdown('uncaughtException').finally(() => process.exit(1));
});

// keep ref to pool so it's tree-shaken-friendly during build
void pool;

export { app, server };
