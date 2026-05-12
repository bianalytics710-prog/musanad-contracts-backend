/**
 * M11 — Admin Ingestion Queue routes.
 *
 * Routes:
 *   GET  /api/v1/admin/ingestion-queue              → list
 *   POST /api/v1/admin/ingestion-queue/:id/resolve  → resolve
 *
 * Rate limiters: authedRead / authedWrite (standard — no heavyExportRateLimiter
 * because there is no paginated CSV export endpoint in CR-D0).
 */

import { Router } from 'express';
import { authenticate, authoriseAnyOf, authorise } from '../../../middleware/auth.middleware';
import { authedReadRateLimiter, authedWriteRateLimiter } from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { ingestionQueueController } from '../../../controllers/admin/ingestion-queue.controller';
import {
  AdminIngestionQueueListQuerySchema,
  AdminIngestionQueueIdParamSchema,
  IngestionResolveBodySchema,
  type AdminIngestionQueueListQuery,
} from '../../../schemas/admin-ingestion-queue.schemas';
import { type ZodSchema } from 'zod';

const router = Router();

/**
 * GET /api/v1/admin/ingestion-queue
 * Gated by document.review OR ingestion_queue.read (either permission suffices).
 */
router.get(
  '/',
  authenticate,
  authoriseAnyOf(['document.review', 'ingestion_queue.read']),
  authedReadRateLimiter,
  validate(AdminIngestionQueueListQuerySchema as ZodSchema<AdminIngestionQueueListQuery>, 'query'),
  ingestionQueueController.list,
);

/**
 * POST /api/v1/admin/ingestion-queue/:id/resolve
 * Gated by document.review (stricter — resolvers must hold review permission).
 */
router.post(
  '/:id/resolve',
  authenticate,
  authorise(['document.review']),
  authedWriteRateLimiter,
  validate(AdminIngestionQueueIdParamSchema, 'params'),
  validate(IngestionResolveBodySchema, 'body'),
  ingestionQueueController.resolve,
);

export default router;
