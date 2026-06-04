/**
 * Admin Risk Scoring Config routes.
 *
 *   GET /api/v1/admin/risk-scoring-config   — fn_risk_scoring_config_get
 *   PUT /api/v1/admin/risk-scoring-config   — fn_risk_scoring_config_set
 *
 * The GET is intentionally widely readable (score.read OR score.weights.manage
 * OR score.config.manage) so the FE hover-card on the gauge can fetch the
 * band thresholds without admin rights — the bands are not sensitive.
 *
 * The PUT is restricted to score.config.manage.
 */
import { Router } from 'express';
import { riskScoringConfigController } from '../../../controllers/admin/risk-scoring-config.controller';
import { authenticate, authorise, authoriseAnyOf } from '../../../middleware/auth.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';

const router = Router();

router.get(
  '/',
  authenticate,
  authoriseAnyOf(['score.read', 'score.weights.manage', 'score.config.manage']),
  authedReadRateLimiter,
  riskScoringConfigController.getConfig,
);

router.put(
  '/',
  authenticate,
  authorise(['score.config.manage']),
  authedWriteRateLimiter,
  riskScoringConfigController.setConfig,
);

export default router;
