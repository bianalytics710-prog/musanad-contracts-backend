/**
 * M8 — /api/v1/admin/internal-signals + /api/v1/admin/internal-signal-kinds
 *      (CR-A2).
 *
 *   POST /admin/internal-signals          authedWriteRateLimiter   ingest
 *   GET  /admin/internal-signal-kinds     authedReadRateLimiter    kinds.list
 *
 * Permission gates live inside the fn_ bodies (internal_signal.ingest /
 * internal_signal.read) — controllers do not double-gate. JWT authentication
 * is mandatory; tenant GUC is set by db.callFunction({ tenantId }) using
 * `req.tenantId` resolved by rls.middleware.
 *
 * Mount note: this file exports TWO routers because the two endpoints live
 * at different paths under /admin (one at /admin/internal-signals, one at
 * /admin/internal-signal-kinds). routes/v1/index.ts mounts both.
 */
import { Router } from 'express';
import { authenticate } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import { validate } from '../../middleware/validation.middleware';
import { adminInternalSignalsController } from '../../controllers/admin/internal-signals.controller';
import { adminInternalSignalKindsController } from '../../controllers/admin/internal-signal-kinds.controller';
import { internalSignalIngestSchema } from '../../schemas/internal-signals.schemas';

// --- /api/v1/admin/internal-signals (POST ingest) ---
const ingestRouter = Router();
ingestRouter.use(authenticate);
ingestRouter.use(rlsMiddleware);

ingestRouter.post(
  '/',
  authedWriteRateLimiter,
  validate(internalSignalIngestSchema, 'body'),
  adminInternalSignalsController.ingest,
);

// --- /api/v1/admin/internal-signal-kinds (GET list) ---
const kindsRouter = Router();
kindsRouter.use(authenticate);
kindsRouter.use(rlsMiddleware);

kindsRouter.get('/', authedReadRateLimiter, adminInternalSignalKindsController.list);

export { ingestRouter as adminInternalSignalsRouter };
export { kindsRouter as adminInternalSignalKindsRouter };
