/**
 * Unit-3 / R-FT — Finance & Treasury persona action routes.
 *
 * Mounted at: /api/v1/finance
 *
 * Endpoint roster:
 *   POST /api/v1/finance/contracts/:contractId/price-review
 *   POST /api/v1/finance/contracts/:contractId/payment-hold
 *   POST /api/v1/finance/contracts/:contractId/hedge-review
 *
 * Permission gates:
 *   price-review: risk.acknowledge AND insights.finance_treasury
 *   payment-hold: risk.acknowledge
 *   hedge-review: risk.acknowledge
 *
 * Middleware stack: authenticate → authedWriteRateLimiter → authorise → validate → controller.
 *
 * NOTE on price-review dual-perm gate:
 *   The API contract requires BOTH risk.acknowledge AND insights.finance_treasury.
 *   We apply authorise(['risk.acknowledge']) first (fast-fail for non-risk users),
 *   then authorise(['insights.finance_treasury']) (finance-specific gate).
 *   Both must pass — this is the "AND" semantics; authoriseAnyOf is OR semantics.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import {
  initiatePriceReview,
  recommendPaymentHold,
  initiateHedgeReview,
} from '../../controllers/finance-actions.controller';
import {
  ContractIdPersonaParamSchema,
  FinancePriceReviewBodySchema,
  FinancePaymentHoldBodySchema,
  FinanceHedgeReviewBodySchema,
} from '../../schemas/persona-actions.schemas';

const financeActionsRouter = Router();

// All routes require an authenticated user.
financeActionsRouter.use(authenticate);

// ------------------------------------------------------------
// POST /api/v1/finance/contracts/:contractId/price-review
// Dual-perm: risk.acknowledge AND insights.finance_treasury.
// ------------------------------------------------------------
financeActionsRouter.post(
  '/contracts/:contractId/price-review',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  authorise(['insights.finance_treasury']),
  validate(ContractIdPersonaParamSchema, 'params'),
  validate(FinancePriceReviewBodySchema, 'body'),
  initiatePriceReview,
);

// ------------------------------------------------------------
// POST /api/v1/finance/contracts/:contractId/payment-hold
// ------------------------------------------------------------
financeActionsRouter.post(
  '/contracts/:contractId/payment-hold',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(ContractIdPersonaParamSchema, 'params'),
  validate(FinancePaymentHoldBodySchema, 'body'),
  recommendPaymentHold,
);

// ------------------------------------------------------------
// POST /api/v1/finance/contracts/:contractId/hedge-review
// ------------------------------------------------------------
financeActionsRouter.post(
  '/contracts/:contractId/hedge-review',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(ContractIdPersonaParamSchema, 'params'),
  validate(FinanceHedgeReviewBodySchema, 'body'),
  initiateHedgeReview,
);

export default financeActionsRouter;
