/**
 * R-LC7 — Impact Watch routes. /api/v1/impact-signals.
 *   GET  /                          list (filter by category / severity / q)
 *   GET  /:id                       get + impacted contracts
 *   POST /links/:linkId/review      mark a signal-contract row reviewed
 *   POST /:id/notify-drafters       fan-out contract_activity to drafters
 *   POST /:id/bulk-amend            emit amendment_initiated for each
 *                                    impacted contract + flip status to amended
 */
import { Router } from 'express';
import { authenticate } from '../../middleware/auth.middleware';
import { authedReadRateLimiter, authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import { validate } from '../../middleware/validation.middleware';
import { impactSignalController } from '../../controllers/impact-signal.controller';
import {
  ImpactSignalListQuerySchema,
  ImpactSignalIdParamSchema,
  ImpactSignalLinkIdParamSchema,
} from '../../schemas/impact-signal.schemas';

const router = Router();
router.use(authenticate);

router.get('/', authedReadRateLimiter, validate(ImpactSignalListQuerySchema, 'query'), impactSignalController.list);
router.get('/:id', authedReadRateLimiter, validate(ImpactSignalIdParamSchema, 'params'), impactSignalController.getById);
router.post(
  '/links/:linkId/review',
  authedWriteRateLimiter,
  validate(ImpactSignalLinkIdParamSchema, 'params'),
  impactSignalController.markReviewed,
);
router.post(
  '/:id/notify-drafters',
  authedWriteRateLimiter,
  validate(ImpactSignalIdParamSchema, 'params'),
  impactSignalController.notifyDrafters,
);
router.post(
  '/:id/bulk-amend',
  authedWriteRateLimiter,
  validate(ImpactSignalIdParamSchema, 'params'),
  impactSignalController.bulkAmend,
);

export default router;
