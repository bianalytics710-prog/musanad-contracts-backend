/**
 * CR-M — Regulatory Cascade routes.
 *
 * All endpoints under /api/v1/regulatory/cascade.
 * Mount: v1Router.use('/regulatory/cascade', regulatoryCascadeRouter)
 *
 * Endpoints:
 *   POST  /                          — run cascade (regulatory.cascade.run)
 *   GET   /                          — list runs (regulatory.cascade.read)
 *   GET   /:runId                    — get run detail (regulatory.cascade.read)
 *   PATCH /items/:itemId/status      — update remediation status (regulatory.cascade.read)
 *   POST  /items/:itemId/draft-amendment — generate advisory draft (advisory.draft.review — legal_counsel / platform_admin / Super Admin only)
 *
 * Route ordering: POST /run must be mounted BEFORE GET /:runId to avoid
 * 'run' being captured as a :runId param. Similarly /items/:itemId/* before /:runId.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { validate } from '../../middleware/validation.middleware';
import { regulatoryCascadeController } from '../../controllers/regulatory-cascade.controller';
import {
  runCascadeSchema,
  cascadeListQuerySchema,
  setRemediationStatusSchema,
  draftAmendmentSchema,
} from '../../schemas/regulatory-cascade.schemas';

const router = Router();

// POST /api/v1/regulatory/cascade/run — execute cascade (regulatory.cascade.run)
router.post(
  '/run',
  authenticate,
  rlsMiddleware,
  authorise(['regulatory.cascade.run']),
  validate(runCascadeSchema, 'body'),
  regulatoryCascadeController.run,
);

// PATCH /api/v1/regulatory/cascade/items/:itemId/status — update remediation
// (mounted BEFORE /:runId to prevent 'items' from matching as runId)
router.patch(
  '/items/:itemId/status',
  authenticate,
  rlsMiddleware,
  authorise(['regulatory.cascade.read']),
  validate(setRemediationStatusSchema, 'body'),
  regulatoryCascadeController.setItemStatus,
);

// POST /api/v1/regulatory/cascade/items/:itemId/draft-amendment — advisory-draft seam
// Requires advisory.draft.review (legal_counsel / platform_admin / Super Admin).
// compliance_esg has regulatory.cascade.run but NOT advisory.draft.review — separation of duties.
router.post(
  '/items/:itemId/draft-amendment',
  authenticate,
  rlsMiddleware,
  authorise(['advisory.draft.review']),
  validate(draftAmendmentSchema, 'body'),
  regulatoryCascadeController.draftAmendment,
);

// GET /api/v1/regulatory/cascade — list runs (regulatory.cascade.read)
router.get(
  '/',
  authenticate,
  rlsMiddleware,
  authorise(['regulatory.cascade.read']),
  validate(cascadeListQuerySchema, 'query'),
  regulatoryCascadeController.list,
);

// GET /api/v1/regulatory/cascade/:runId — get run detail (regulatory.cascade.read)
router.get(
  '/:runId',
  authenticate,
  rlsMiddleware,
  authorise(['regulatory.cascade.read']),
  regulatoryCascadeController.get,
);

export default router;
