/**
 * M14 / CR-F — Admin Scoring Weights Routes.
 *
 * Route summary (all under /admin/scoring-weights):
 *   GET    /api/v1/admin/scoring-weights            — fn_scoring_weights_get (score.weights.manage)
 *   PATCH  /api/v1/admin/scoring-weights            — fn_scoring_weights_set (score.weights.manage)
 *   POST   /api/v1/admin/scoring-weights/recompute-all — fn_score_recompute_for_weight_change (score.weights.manage)
 *
 * Route ordering:
 *   /recompute-all (literal POST) must be mounted BEFORE any /:id wildcard — but
 *   this router has no wildcard routes so ordering is for clarity only.
 *
 * Rate limits:
 *   - GET: authedReadRateLimiter (120/min/user)
 *   - PATCH: authedWriteRateLimiter (60/min/user)
 *   - POST /recompute-all: heavyExportRateLimiter (5/min/user — long-running bulk job)
 *     per agent 07 B15 pattern: heavy endpoint = dedicated tighter rate limiter.
 */
import { Router } from 'express';
import { scoringWeightsController } from '../../../controllers/admin/scoring-weights.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
  heavyExportRateLimiter,
} from '../../../middleware/rate-limit.middleware';
import { patchScoringWeightsBodySchema } from '../../../schemas/risk-score.schemas';
import { CR_F_PERMISSION_SCORE_WEIGHTS_MANAGE } from '../../../types/risk-score.types';

const router = Router();

// CR-F-006 — POST /admin/scoring-weights/recompute-all
// MUST be registered before the bare PATCH route to avoid any future /:segment clash.
router.post(
  '/recompute-all',
  authenticate,
  authorise([CR_F_PERMISSION_SCORE_WEIGHTS_MANAGE]),
  heavyExportRateLimiter,
  scoringWeightsController.recomputeAll,
);

// CR-F-004 — GET /admin/scoring-weights
router.get(
  '/',
  authenticate,
  authorise([CR_F_PERMISSION_SCORE_WEIGHTS_MANAGE]),
  authedReadRateLimiter,
  scoringWeightsController.getWeights,
);

// CR-F-005 — PATCH /admin/scoring-weights
router.patch(
  '/',
  authenticate,
  authorise([CR_F_PERMISSION_SCORE_WEIGHTS_MANAGE]),
  authedWriteRateLimiter,
  validate(patchScoringWeightsBodySchema, 'body'),
  scoringWeightsController.setWeights,
);

export default router;
