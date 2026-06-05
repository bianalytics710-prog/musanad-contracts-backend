/**
 * Internal-systems admin routes — Platform Admin registry of internal
 * integrations (ERP / Finance / HRMS / CRM / etc.).
 *
 *   GET    /api/v1/admin/internal-systems                   list
 *   POST   /api/v1/admin/internal-systems                   create
 *   POST   /api/v1/admin/internal-systems/:id/test-connection  probe + set health
 *   GET    /api/v1/admin/internal-systems/:id               get
 *   PUT    /api/v1/admin/internal-systems/:id               update
 *   DELETE /api/v1/admin/internal-systems/:id               soft-delete
 *
 * Route ordering: literal segments ('/:id/test-connection') must come
 * BEFORE the bare /:id PUT/DELETE so Express doesn't capture 'test-connection'
 * inside the id parameter.
 *
 * Permission: platform.integrations.manage (route-layer + fn body).
 */
import { Router } from 'express';
import { internalSystemsController } from '../../../controllers/admin/internal-systems.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);
router.use(authorise(['platform.integrations.manage']));

router.get('/', authedReadRateLimiter, internalSystemsController.list);
router.post('/', authedWriteRateLimiter, internalSystemsController.create);

// Literal /:id/test-connection BEFORE the bare /:id PUT/DELETE.
router.post(
  '/:id/test-connection',
  authedWriteRateLimiter,
  internalSystemsController.testConnection,
);

router.get('/:id', authedReadRateLimiter, internalSystemsController.get);
router.put('/:id', authedWriteRateLimiter, internalSystemsController.update);
router.delete('/:id', authedWriteRateLimiter, internalSystemsController.deactivate);

export default router;
