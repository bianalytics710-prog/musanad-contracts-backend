/**
 * M7 — /api/v1/admin/sources/* (CR-A).
 *
 *   GET    /                       authedReadRateLimiter   adminSourcesController.list
 *   POST   /                       authedWriteRateLimiter  adminSourcesController.create
 *   GET    /:id                    authedReadRateLimiter   adminSourcesController.getById
 *   PATCH  /:id                    authedWriteRateLimiter  adminSourcesController.update
 *   DELETE /:id                    authedWriteRateLimiter  adminSourcesController.delete
 *   POST   /:id/test-pull          authedWriteRateLimiter  adminSourcesController.testPull
 *   POST   /:id/credential         authedWriteRateLimiter  adminSourcesController.setCredential
 *
 * Permission gates live inside the fn_ bodies (source.read / source.manage)
 * — controllers do not double-gate. JWT authentication is mandatory; tenant
 * GUC is set by db.callFunction({ tenantId }) using `req.tenantId` resolved
 * by rls.middleware.
 */
import { Router } from 'express';
import { authenticate } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import { validate } from '../../middleware/validation.middleware';
import { adminSourcesController } from '../../controllers/admin/sources.controller';
import {
  osintSourceListQuerySchema,
  osintSourceIdParamSchema,
  createOsintSourceSchema,
  updateOsintSourceSchema,
  setCredentialSchema,
} from '../../schemas/admin-sources.schemas';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

router.get(
  '/',
  authedReadRateLimiter,
  validate(osintSourceListQuerySchema, 'query'),
  adminSourcesController.list,
);

router.post(
  '/',
  authedWriteRateLimiter,
  validate(createOsintSourceSchema, 'body'),
  adminSourcesController.create,
);

router.get(
  '/:id',
  authedReadRateLimiter,
  validate(osintSourceIdParamSchema, 'params'),
  adminSourcesController.getById,
);

router.patch(
  '/:id',
  authedWriteRateLimiter,
  validate(osintSourceIdParamSchema, 'params'),
  validate(updateOsintSourceSchema, 'body'),
  adminSourcesController.update,
);

router.delete(
  '/:id',
  authedWriteRateLimiter,
  validate(osintSourceIdParamSchema, 'params'),
  adminSourcesController.delete,
);

router.post(
  '/:id/test-pull',
  authedWriteRateLimiter,
  validate(osintSourceIdParamSchema, 'params'),
  adminSourcesController.testPull,
);

router.post(
  '/:id/credential',
  authedWriteRateLimiter,
  validate(osintSourceIdParamSchema, 'params'),
  validate(setCredentialSchema, 'body'),
  adminSourcesController.setCredential,
);

export default router;
