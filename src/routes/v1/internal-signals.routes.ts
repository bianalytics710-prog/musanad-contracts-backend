/**
 * M8 — /api/v1/internal-signals (CR-A2).
 *
 *   GET  /                authedReadRateLimiter    list   (fn_internal_signal_list)
 *   POST /:id/resolve     authedWriteRateLimiter   resolve (fn_internal_signal_resolve)
 *
 * Permissions (gated inside fn_ bodies — defence-in-depth):
 *   - GET           → internal_signal.read
 *   - POST resolve  → internal_signal.resolve + per-signal_type role
 *                     allowlist (Q-DA3 hardcoded mapping in fn body).
 *
 * JWT authentication is mandatory; tenant GUC is set by db.callFunction
 * ({ tenantId }) using `req.tenantId` resolved by rls.middleware.
 */
import { Router } from 'express';
import { authenticate } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import { validate } from '../../middleware/validation.middleware';
import { internalSignalsController } from '../../controllers/internal-signals.controller';
import {
  internalSignalIdParamSchema,
  internalSignalListQuerySchema,
  internalSignalResolveSchema,
} from '../../schemas/internal-signals.schemas';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

router.get(
  '/',
  authedReadRateLimiter,
  validate(internalSignalListQuerySchema, 'query'),
  internalSignalsController.list,
);

router.post(
  '/:id/resolve',
  authedWriteRateLimiter,
  validate(internalSignalIdParamSchema, 'params'),
  validate(internalSignalResolveSchema, 'body'),
  internalSignalsController.resolve,
);

export default router;
