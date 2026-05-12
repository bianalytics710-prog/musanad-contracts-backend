/**
 * M11 — Document Ingestion sub-routes.
 *
 * Mounted under /api/v1/contracts/:id/versions/:vId (sub-path).
 *
 * Routes:
 *   POST /ingest             → manualIngest (document.ingest — Super Admin)
 *   GET  /extracted-text     → getExtractedTextSignedUrl (contract.read.*)
 *   GET  /ingestion-status   → getIngestionStatus (contract.read.*)
 *
 * Rate limiters:
 *   POST: authedWriteRateLimiter (60/min/user)
 *   GET:  authedReadRateLimiter (120/min/user)
 *
 * Note: Express router param inheritance — :id and :vId are defined in the
 * parent contracts router and passed down via mergeParams: true.
 */

import { Router } from 'express';
import { authenticate, authorise, authoriseAnyOf } from '../../../middleware/auth.middleware';
import { authedReadRateLimiter, authedWriteRateLimiter } from '../../../middleware/rate-limit.middleware';
import { documentIngestionController } from '../../../controllers/document-ingestion.controller';

const router = Router({ mergeParams: true });

/**
 * POST /api/v1/contracts/:id/versions/:vId/ingest
 * Manual extraction trigger. Gated by document.ingest.
 */
router.post(
  '/ingest',
  authenticate,
  authorise(['document.ingest']),
  authedWriteRateLimiter,
  documentIngestionController.manualIngest,
);

/**
 * GET /api/v1/contracts/:id/versions/:vId/extracted-text
 * Signed URL for extracted text. Gated by any contract.read.* permission.
 */
router.get(
  '/extracted-text',
  authenticate,
  authoriseAnyOf(['contract.read.all', 'contract.read.department', 'contract.read.own']),
  authedReadRateLimiter,
  documentIngestionController.getExtractedTextSignedUrl,
);

/**
 * GET /api/v1/contracts/:id/versions/:vId/ingestion-status
 * Ingestion status poll. Gated by any contract.read.* permission.
 */
router.get(
  '/ingestion-status',
  authenticate,
  authoriseAnyOf(['contract.read.all', 'contract.read.department', 'contract.read.own']),
  authedReadRateLimiter,
  documentIngestionController.getIngestionStatus,
);

export default router;
