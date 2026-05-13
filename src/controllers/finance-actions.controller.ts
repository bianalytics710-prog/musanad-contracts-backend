/**
 * Unit-3 / R-FT — Finance & Treasury persona action controllers.
 *
 * Routes handled:
 *   POST /api/v1/finance/contracts/:contractId/price-review
 *   POST /api/v1/finance/contracts/:contractId/payment-hold
 *   POST /api/v1/finance/contracts/:contractId/hedge-review
 *
 * Permission: risk.acknowledge (all 3 routes).
 *   price-review also requires insights.finance_treasury — gated at route
 *   layer with authoriseAnyOf(['risk.acknowledge']) + authorise(['insights.finance_treasury']).
 *
 * Audit: fn_audit_log_record_v2 via persona-actions.service.
 *
 * Pattern: Route → Controller → service → db.callFunction → JSONB response.
 * No business logic in this file. One service call per handler.
 */
import type { NextFunction, Request, Response } from 'express';
import { ADNOC_TENANT_ID } from '../middleware/rls.middleware';
import { personaActionsService } from '../services/persona-actions.service';
import type {
  FinancePriceReviewBody,
  FinancePaymentHoldBody,
  FinanceHedgeReviewBody,
  ContractIdPersonaParam,
} from '../schemas/persona-actions.schemas';

// ---------------------------------------------------------------------------
// Initiate price review
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/finance/contracts/:contractId/price-review
 * Perm: risk.acknowledge AND insights.finance_treasury.
 */
export const initiatePriceReview = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'price_review_initiated',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const { correlationId, reason, note } = req.body as FinancePriceReviewBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.initiatePriceReview(
      actorId,
      contractIdNum,
      correlationId,
      reason,
      note,
      tenantId,
    );

    req.logger.info({
      action: 'price_review_initiated',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'price_review_initiated',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Recommend payment hold
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/finance/contracts/:contractId/payment-hold
 * Perm: risk.acknowledge.
 */
export const recommendPaymentHold = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'payment_hold_recommended',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const { invoiceRef, amountAed, note } = req.body as FinancePaymentHoldBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.recommendPaymentHold(
      actorId,
      contractIdNum,
      invoiceRef,
      amountAed,
      note,
      tenantId,
    );

    req.logger.info({
      action: 'payment_hold_recommended',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'payment_hold_recommended',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Initiate hedge review
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/finance/contracts/:contractId/hedge-review
 * Perm: risk.acknowledge.
 */
export const initiateHedgeReview = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'hedge_review_initiated',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const { pair, exposureAed, note } = req.body as FinanceHedgeReviewBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.initiateHedgeReview(
      actorId,
      contractIdNum,
      pair,
      exposureAed,
      note,
      tenantId,
    );

    req.logger.info({
      action: 'hedge_review_initiated',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'hedge_review_initiated',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};
