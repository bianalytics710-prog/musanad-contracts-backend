/**
 * M13 / CR-E — Correlation Rule Engine + DSL Routes.
 *
 * Route summary:
 *   GET    /api/v1/admin/rules           CR-E-001 (correlation.rule.read)
 *   POST   /api/v1/admin/rules           CR-E-002 (correlation.rule.manage)
 *   PATCH  /api/v1/admin/rules/:id       CR-E-003 (correlation.rule.manage)
 *   POST   /api/v1/admin/rules/:id/test  CR-E-004 (correlation.rule.manage)
 *   GET    /api/v1/admin/rules/:id       CR-E-007 (correlation.rule.read)
 *   DELETE /api/v1/admin/rules/:id       CR-E-008 (correlation.rule.manage)
 *   GET    /api/v1/correlations          CR-E-005 (correlation.read)
 *   POST   /api/v1/correlations/:id/dismiss  CR-E-006 (correlation.dismiss)
 *
 * Route ordering (W1):
 *   /admin/rules (literal) before /:id routes.
 *   /:id/test before /:id for POST namespace disambiguation.
 *
 * Rate limits:
 *   - GETs: authedReadRateLimiter (120/min/user)
 *   - Writes: authedWriteRateLimiter (60/min/user)
 */
import { Router } from 'express';
import { correlationRuleController } from '../../controllers/correlation-rule.controller';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import {
  RuleIdParamsSchema,
  CorrelationIdParamsSchema,
  RuleListQuerySchema,
  CreateRuleBodySchema,
  UpdateRuleBodySchema,
  TestRuleBodySchema,
  CorrelationListQuerySchema,
  CorrelationDismissBodySchema,
} from '../../schemas/correlation-rule.schemas';

// ============================================================
// Admin rules sub-router (mounted under /admin/rules in admin/index.ts)
// ============================================================

export const adminRulesRouter = Router();

// CR-E-001 — GET /admin/rules
adminRulesRouter.get(
  '/',
  authenticate,
  authorise(['rule.read']),
  authedReadRateLimiter,
  validate(RuleListQuerySchema, 'query'),
  correlationRuleController.listRules,
);

// CR-E-002 — POST /admin/rules
adminRulesRouter.post(
  '/',
  authenticate,
  authorise(['rule.manage']),
  authedWriteRateLimiter,
  validate(CreateRuleBodySchema, 'body'),
  correlationRuleController.createRule,
);

// CR-E-004 — POST /admin/rules/:id/test (MUST be before /:id routes)
adminRulesRouter.post(
  '/:id/test',
  authenticate,
  authorise(['rule.manage']),
  authedWriteRateLimiter,
  validate(RuleIdParamsSchema, 'params'),
  validate(TestRuleBodySchema, 'body'),
  correlationRuleController.testRule,
);

// CR-E-007 — GET /admin/rules/:id
adminRulesRouter.get(
  '/:id',
  authenticate,
  authorise(['rule.read']),
  authedReadRateLimiter,
  validate(RuleIdParamsSchema, 'params'),
  correlationRuleController.getRuleById,
);

// CR-E-003 — PATCH /admin/rules/:id
adminRulesRouter.patch(
  '/:id',
  authenticate,
  authorise(['rule.manage']),
  authedWriteRateLimiter,
  validate(RuleIdParamsSchema, 'params'),
  validate(UpdateRuleBodySchema, 'body'),
  correlationRuleController.updateRule,
);

// CR-E-008 — DELETE /admin/rules/:id
adminRulesRouter.delete(
  '/:id',
  authenticate,
  authorise(['rule.manage']),
  authedWriteRateLimiter,
  validate(RuleIdParamsSchema, 'params'),
  correlationRuleController.deleteRule,
);

// ============================================================
// Correlations sub-router (mounted under /correlations in v1/index.ts)
// ============================================================

export const correlationsRouter = Router();

// CR-E-005 — GET /correlations
correlationsRouter.get(
  '/',
  authenticate,
  authorise(['correlation.read']),
  authedReadRateLimiter,
  validate(CorrelationListQuerySchema, 'query'),
  correlationRuleController.listCorrelations,
);

// CR-E-006 — POST /correlations/:id/dismiss
correlationsRouter.post(
  '/:id/dismiss',
  authenticate,
  authorise(['correlation.dismiss']),
  authedWriteRateLimiter,
  validate(CorrelationIdParamsSchema, 'params'),
  validate(CorrelationDismissBodySchema, 'body'),
  correlationRuleController.dismissCorrelation,
);
