/**
 * CR-N — Financial Budget Burn routes.
 *
 * All endpoints under /api/v1/financial/budget-burn.
 * Mount: v1Router.use('/financial/budget-burn', financialBudgetBurnRouter)
 *
 * Route ordering: literal-path routes MUST be registered BEFORE parameterised routes
 * to avoid Express matching 'budgets', 'cost-actuals', or 'variance' as a :contractId param.
 *
 * CRITICAL (CR-M DEFECT-CRM-ROUTES-1 lesson):
 *   Every route MUST include rlsMiddleware between authenticate and authorise so the
 *   tenant GUC (app.current_tenant_id, app.current_user_id) is set before fn_ calls.
 *
 * Endpoints (ordered — literals first):
 *   GET  /                              — portfolio (finance.budget.read)
 *   GET  /budgets                       — list budget lines (finance.budget.read)
 *   GET  /budgets/:id                   — get budget line by id (finance.budget.read)
 *   GET  /cost-actuals                  — list cost actuals (finance.budget.read)
 *   POST /variance/:contractId/draft-cure-notice  — cure-notice draft (advisory.draft.review)
 *   GET  /:contractId                   — burn compute (finance.budget.read)
 *   GET  /:contractId/variance          — variance + clauses (finance.budget.read)
 *   GET  /:contractId/projection        — year-end projection (finance.budget.read)
 *   POST /:contractId/cost-actuals      — record actual (finance.budget.manage)
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { validate } from '../../middleware/validation.middleware';
import { financialBudgetBurnController } from '../../controllers/financial-budget-burn.controller';
import {
  portfolioQuerySchema,
  budgetListQuerySchema,
  costActualListQuerySchema,
  budgetBurnVarianceQuerySchema,
  budgetProjectionQuerySchema,
  recordCostActualSchema,
  draftCureNoticeSchema,
} from '../../schemas/budget-burn.schemas';

const router = Router();

// ---------------------------------------------------------------------------
// Literal-path routes (MUST come before /:contractId)
// ---------------------------------------------------------------------------

// GET /api/v1/financial/budget-burn — portfolio rollup
router.get(
  '/',
  authenticate,
  rlsMiddleware,
  authorise(['finance.budget.read']),
  validate(portfolioQuerySchema, 'query'),
  financialBudgetBurnController.portfolio,
);

// GET /api/v1/financial/budget-burn/budgets — list budget lines
router.get(
  '/budgets',
  authenticate,
  rlsMiddleware,
  authorise(['finance.budget.read']),
  validate(budgetListQuerySchema, 'query'),
  financialBudgetBurnController.listBudgets,
);

// GET /api/v1/financial/budget-burn/budgets/:id — get budget line by id
router.get(
  '/budgets/:id',
  authenticate,
  rlsMiddleware,
  authorise(['finance.budget.read']),
  financialBudgetBurnController.getBudgetById,
);

// GET /api/v1/financial/budget-burn/cost-actuals — list actuals
router.get(
  '/cost-actuals',
  authenticate,
  rlsMiddleware,
  authorise(['finance.budget.read']),
  validate(costActualListQuerySchema, 'query'),
  financialBudgetBurnController.listCostActuals,
);

// POST /api/v1/financial/budget-burn/variance/:contractId/draft-cure-notice
// NOTE: 'variance' literal prefix prevents /:contractId from capturing this path
router.post(
  '/variance/:contractId/draft-cure-notice',
  authenticate,
  rlsMiddleware,
  authorise(['advisory.draft.review']),
  validate(draftCureNoticeSchema, 'body'),
  financialBudgetBurnController.draftCureNotice,
);

// ---------------------------------------------------------------------------
// Parameterised routes (/:contractId and sub-routes)
// ---------------------------------------------------------------------------

// GET /api/v1/financial/budget-burn/:contractId — burn compute
router.get(
  '/:contractId',
  authenticate,
  rlsMiddleware,
  authorise(['finance.budget.read']),
  financialBudgetBurnController.computeBurn,
);

// GET /api/v1/financial/budget-burn/:contractId/variance
router.get(
  '/:contractId/variance',
  authenticate,
  rlsMiddleware,
  authorise(['finance.budget.read']),
  validate(budgetBurnVarianceQuerySchema, 'query'),
  financialBudgetBurnController.getVariance,
);

// GET /api/v1/financial/budget-burn/:contractId/projection
router.get(
  '/:contractId/projection',
  authenticate,
  rlsMiddleware,
  authorise(['finance.budget.read']),
  validate(budgetProjectionQuerySchema, 'query'),
  financialBudgetBurnController.getProjection,
);

// GET /api/v1/financial/budget-burn/:contractId/milestones
// mig 594 — event-based milestone list
router.get(
  '/:contractId/milestones',
  authenticate,
  rlsMiddleware,
  authorise(['finance.budget.read']),
  financialBudgetBurnController.listMilestones,
);

// POST /api/v1/financial/budget-burn/:contractId/cost-actuals
router.post(
  '/:contractId/cost-actuals',
  authenticate,
  rlsMiddleware,
  authorise(['finance.budget.manage']),
  validate(recordCostActualSchema, 'body'),
  financialBudgetBurnController.recordCostActual,
);

export default router;
