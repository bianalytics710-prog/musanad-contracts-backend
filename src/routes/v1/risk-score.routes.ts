/**
 * M14 / CR-F — Risk Score Routes.
 *
 * Route summary:
 *   GET /api/v1/contracts/:id/risk-score          — fn_risk_score_explain (score.read)
 *   GET /api/v1/contracts/:id/risk-score/history  — fn_risk_score_history (score.read)
 *   GET /api/v1/risk/avar                         — fn_avar_aggregate (score.read)
 *
 * NOTE on mount order:
 *   /risk-score/history must be registered before /risk-score because Express matches
 *   routes in order — if the bare /risk-score route was first and used a wildcard,
 *   the /history suffix would be swallowed. Both are GET with literal paths so order
 *   only matters within the same router instance.
 *
 * Rate limits:
 *   All reads: authedReadRateLimiter (120/min/user — project default for authenticated reads).
 */
import { Router } from 'express';
import { riskScoreController } from '../../controllers/risk-score.controller';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import {
  contractIdParamsSchema,
  getRiskScoreHistoryQuerySchema,
} from '../../schemas/risk-score.schemas';
import { CR_F_PERMISSION_SCORE_READ } from '../../types/risk-score.types';

// ============================================================
// Contract risk-score sub-router
// Mounted under /contracts in v1/index.ts (alongside extractClausesRouter).
// ============================================================

export const contractRiskScoreRouter = Router({ mergeParams: true });

// CR-F-002 — GET /contracts/:id/risk-score/history (MUST be before /risk-score plain)
contractRiskScoreRouter.get(
  '/:id/risk-score/history',
  authenticate,
  authorise([CR_F_PERMISSION_SCORE_READ]),
  authedReadRateLimiter,
  validate(contractIdParamsSchema, 'params'),
  validate(getRiskScoreHistoryQuerySchema, 'query'),
  riskScoreController.getRiskScoreHistory,
);

// CR-F-001 — GET /contracts/:id/risk-score
contractRiskScoreRouter.get(
  '/:id/risk-score',
  authenticate,
  authorise([CR_F_PERMISSION_SCORE_READ]),
  authedReadRateLimiter,
  validate(contractIdParamsSchema, 'params'),
  riskScoreController.getRiskScoreExplain,
);

// ============================================================
// Risk (AVaR) sub-router
// Mounted under /risk in v1/index.ts.
// ============================================================

import { getAvarQuerySchema } from '../../schemas/risk-score.schemas';

export const riskAvarRouter = Router();

// CR-F-003 — GET /risk/avar
riskAvarRouter.get(
  '/avar',
  authenticate,
  authorise([CR_F_PERMISSION_SCORE_READ]),
  authedReadRateLimiter,
  validate(getAvarQuerySchema, 'query'),
  riskScoreController.getAvar,
);
