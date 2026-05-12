/**
 * M12 / CR-D — Clause Extraction + Taxonomy + Review Routes.
 *
 * Route summary:
 *   POST /api/v1/contracts/:id/extract-clauses                   CR-D-001 (clause.extract)
 *   POST /api/v1/contracts/:id/versions/:vId/extract-clauses     CR-D-002 (clause.extract)
 *   GET  /api/v1/clauses/review-queue                            CR-D-003 (clause.review)
 *   POST /api/v1/clauses/:id/review                              CR-D-004 (clause.review)
 *   POST /api/v1/clauses/search                                  CR-D-006 (clause.search)
 *   (CR-D-005 /admin/clause-taxonomy is mounted in admin/index.ts)
 *
 * Route ordering (W1): literal-path routes BEFORE /:id routes.
 *   /clauses/review-queue and /clauses/search MUST appear before /clauses/:id/review.
 *
 * Rate limits:
 *   - GETs: authedReadRateLimiter (120/min/user)
 *   - Writes/triggers: authedWriteRateLimiter (60/min/user)
 *   - Semantic search: authedReadRateLimiter (embedding call is fast; heavy limit not needed)
 */
import { Router } from 'express';
import { clauseExtractionController } from '../../controllers/clause-extraction.controller';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import {
  ContractIdParamsSchema,
  ContractVersionParamsSchema,
  ClauseIdParamsSchema,
  ExtractClausesBodySchema,
  ClauseReviewQueueQuerySchema,
  ClauseReviewBodySchema,
  ClauseSemanticSearchBodySchema,
} from '../../schemas/clause-extraction.schemas';

// ============================================================
// Extract-clauses routes (mounted under /contracts in v1/index.ts)
// ============================================================

export const extractClausesRouter = Router();

// CR-D-001 — POST /api/v1/contracts/:id/extract-clauses
extractClausesRouter.post(
  '/:id/extract-clauses',
  authenticate,
  authorise(['clause.extract']),
  authedWriteRateLimiter,
  validate(ContractIdParamsSchema, 'params'),
  validate(ExtractClausesBodySchema, 'body'),
  clauseExtractionController.extractClausesLatestVersion,
);

// CR-D-002 — POST /api/v1/contracts/:id/versions/:vId/extract-clauses
extractClausesRouter.post(
  '/:id/versions/:vId/extract-clauses',
  authenticate,
  authorise(['clause.extract']),
  authedWriteRateLimiter,
  validate(ContractVersionParamsSchema, 'params'),
  validate(ExtractClausesBodySchema, 'body'),
  clauseExtractionController.extractClausesSpecificVersion,
);

// ============================================================
// Clause review + search routes (mounted under /clauses in v1/index.ts)
// ============================================================

export const clauseReviewRouter = Router();

// CR-D-003 — GET /api/v1/clauses/review-queue (MUST be before /:id routes)
clauseReviewRouter.get(
  '/review-queue',
  authenticate,
  authorise(['clause.review']),
  authedReadRateLimiter,
  validate(ClauseReviewQueueQuerySchema, 'query'),
  clauseExtractionController.listReviewQueue,
);

// CR-D-006 — POST /api/v1/clauses/search (MUST be before /:id routes)
clauseReviewRouter.post(
  '/search',
  authenticate,
  authorise(['clause.search']),
  authedReadRateLimiter,
  validate(ClauseSemanticSearchBodySchema, 'body'),
  clauseExtractionController.semanticSearch,
);

// CR-D-004 — POST /api/v1/clauses/:id/review
clauseReviewRouter.post(
  '/:id/review',
  authenticate,
  authorise(['clause.review']),
  authedWriteRateLimiter,
  validate(ClauseIdParamsSchema, 'params'),
  validate(ClauseReviewBodySchema, 'body'),
  clauseExtractionController.reviewClause,
);
