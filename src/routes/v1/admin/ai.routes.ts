/**
 * /api/v1/admin/ai/* — M4 admin observability routes.
 *
 * Permission gate: ai.observability.read (granted to Super Admin +
 * platform_admin per migration 044).
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { authedReadRateLimiter } from '../../../middleware/rate-limit.middleware';
import { adminAiInsightsController } from '../../../controllers/admin/ai-insights.controller';
import { adminAiRequestsController } from '../../../controllers/admin/ai-requests.controller';
import { adminAiCostReportController } from '../../../controllers/admin/ai-cost-report.controller';
import { adminAiPromptsController } from '../../../controllers/admin/ai-prompts.controller';
import {
  aiCostReportQuerySchema,
  aiInsightListQuerySchema,
  aiPromptListQuerySchema,
  aiRequestLogListQuerySchema,
} from '../../../schemas/ai.schemas';

const router = Router();

router.use(authenticate);
router.use(authorise(['ai.observability.read']));

// S11 — GET /api/v1/admin/ai/insights
router.get(
  '/insights',
  authedReadRateLimiter,
  validate(aiInsightListQuerySchema, 'query'),
  adminAiInsightsController.list,
);

// S11 — GET /api/v1/admin/ai/requests
router.get(
  '/requests',
  authedReadRateLimiter,
  validate(aiRequestLogListQuerySchema, 'query'),
  adminAiRequestsController.list,
);

// S12 — GET /api/v1/admin/ai/cost-report
router.get(
  '/cost-report',
  authedReadRateLimiter,
  validate(aiCostReportQuerySchema, 'query'),
  adminAiCostReportController.report,
);

// S13 — GET /api/v1/admin/ai/prompts
router.get(
  '/prompts',
  authedReadRateLimiter,
  validate(aiPromptListQuerySchema, 'query'),
  adminAiPromptsController.list,
);

export default router;
