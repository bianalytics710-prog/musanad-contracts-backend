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
    `Musanad Contracts backend listening on port ${port}`,
  );
});

// --- Graceful shutdown ---
const shutdown = async (signal: string): Promise<void> => {
  logger.info({ action: 'server.shutdown', signal }, 'Shutdown initiated');
  try {
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
