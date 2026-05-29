/**
 * CR-N — Financial Budget Burn controller.
 *
 * Thin controller: Pino entry/exit log → Zod validate → db.callFunction() → response.
 * For the cure-notice draft endpoint, delegates to budget-cure-notice-draft.service.ts.
 *
 * JSONB envelope: all fn_ functions return JSONB objects directly (not wrapped in
 * { success, data }). Controllers return the raw fn_ result via res.json() — same
 * pattern as regulatory-cascade.controller.ts (confirmed by reading that file).
 * The HTTP client framework wraps in success/data if needed at the API layer.
 *
 * NULL handling per fn_ specs:
 *   fn_budget_burn_compute       → NULL if contract not found → 404
 *   fn_budget_variance_for_contract → NULL if contract not found → 404
 *   fn_budget_year_end_projection → NULL if contract not found → 404
 *   fn_budget_burn_portfolio     → never NULL (returns zeros)
 *   fn_contract_budget_list      → never NULL
 *   fn_contract_budget_get       → NULL if not found → 404
 *   fn_contract_cost_actual_list → never NULL
 *   fn_contract_cost_actual_record → always returns the upserted row
 *
 * Money fields: NUMERIC(18,2) returned as ::text string by all fn_'s.
 * No coercion to number — preserve string on the wire (contracts.md DESIGN NOTE 1).
 *
 * Endpoints:
 *   GET  /api/v1/financial/budget-burn             (portfolio)
 *   GET  /api/v1/financial/budget-burn/budgets
 *   GET  /api/v1/financial/budget-burn/budgets/:id
 *   GET  /api/v1/financial/budget-burn/cost-actuals
 *   GET  /api/v1/financial/budget-burn/:contractId
 *   GET  /api/v1/financial/budget-burn/:contractId/variance
 *   GET  /api/v1/financial/budget-burn/:contractId/projection
 *   POST /api/v1/financial/budget-burn/:contractId/cost-actuals
 *   POST /api/v1/financial/budget-burn/variance/:contractId/draft-cure-notice
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import {
  portfolioQuerySchema,
  budgetListQuerySchema,
  budgetIdParamSchema,
  costActualListQuerySchema,
  contractIdParamSchema,
  budgetBurnVarianceQuerySchema,
  budgetProjectionQuerySchema,
  recordCostActualSchema,
  draftCureNoticeSchema,
} from '../schemas/budget-burn.schemas';
import { generateBudgetCureNoticeDraft } from '../services/budget-cure-notice-draft.service';

export const financialBudgetBurnController = {

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/budget-burn  (portfolio — no path param)
  // -------------------------------------------------------------------------
  portfolio: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_budget_burn_portfolio',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = portfolioQuerySchema.parse(req.query);

      const filters = {
        fiscalYear:     params.fiscalYear     ?? null,
        minVariancePct: params.minVariancePct ?? null,
        costCategory:   params.costCategory   ?? null,
        page:           params.page,
        limit:          params.limit,
      };

      const result = await db.callFunction(
        'fn_budget_burn_portfolio',
        [req.user!.id, filters],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_budget_burn_portfolio',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_budget_burn_portfolio',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/budget-burn/budgets
  // -------------------------------------------------------------------------
  listBudgets: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_contract_budget_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = budgetListQuerySchema.parse(req.query);

      const result = await db.callFunction(
        'fn_contract_budget_list',
        [
          req.user!.id,
          params.contractId   ?? null,
          params.fiscalYear   ?? null,
          params.costCategory ?? null,
          params.page,
          params.limit,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_contract_budget_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_contract_budget_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/budget-burn/budgets/:id
  // -------------------------------------------------------------------------
  getBudgetById: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_contract_budget_get',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { id } = budgetIdParamSchema.parse(req.params);

      const result = await db.callFunction(
        'fn_contract_budget_get',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'budget_not_found', 'Budget line not found');

      req.logger.info({
        action: 'fn_contract_budget_get',
        userId: req.user?.id,
        budgetId: id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_contract_budget_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/budget-burn/cost-actuals
  // -------------------------------------------------------------------------
  listCostActuals: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_contract_cost_actual_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = costActualListQuerySchema.parse(req.query);

      const result = await db.callFunction(
        'fn_contract_cost_actual_list',
        [
          req.user!.id,
          params.contractId   ?? null,
          params.fiscalYear   ?? null,
          params.costCategory ?? null,
          params.periodLabel  ?? null,
          params.page,
          params.limit,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_contract_cost_actual_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_contract_cost_actual_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/budget-burn/:contractId
  // -------------------------------------------------------------------------
  computeBurn: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_budget_burn_compute',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { contractId } = contractIdParamSchema.parse(req.params);

      const result = await db.callFunction(
        'fn_budget_burn_compute',
        [req.user!.id, contractId],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'contract_not_found', 'Contract not found or no budget data available');

      req.logger.info({
        action: 'fn_budget_burn_compute',
        userId: req.user?.id,
        contractId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_budget_burn_compute',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/budget-burn/:contractId/variance
  // -------------------------------------------------------------------------
  getVariance: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_budget_variance_for_contract',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { contractId } = contractIdParamSchema.parse(req.params);
      const query = budgetBurnVarianceQuerySchema.parse(req.query);

      const result = await db.callFunction(
        'fn_budget_variance_for_contract',
        [req.user!.id, contractId, query.thresholdPct ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'contract_not_found', 'Contract not found or no budget data available');

      req.logger.info({
        action: 'fn_budget_variance_for_contract',
        userId: req.user?.id,
        contractId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_budget_variance_for_contract',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/budget-burn/:contractId/projection
  // -------------------------------------------------------------------------
  getProjection: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_budget_year_end_projection',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { contractId } = contractIdParamSchema.parse(req.params);
      const query = budgetProjectionQuerySchema.parse(req.query);

      const result = await db.callFunction(
        'fn_budget_year_end_projection',
        [req.user!.id, contractId, query.asOfPeriod ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'contract_not_found', 'Contract not found or no budget data available');

      // Note: confidenceNote='insufficient_data' with null projection fields is a valid 200
      // (no actuals yet ≠ contract not found — per db-design.md fn spec)

      req.logger.info({
        action: 'fn_budget_year_end_projection',
        userId: req.user?.id,
        contractId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_budget_year_end_projection',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // POST /api/v1/financial/budget-burn/:contractId/cost-actuals
  // -------------------------------------------------------------------------
  recordCostActual: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_contract_cost_actual_record',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { contractId } = contractIdParamSchema.parse(req.params);
      const data = recordCostActualSchema.parse(req.body);

      const result = await db.callFunction(
        'fn_contract_cost_actual_record',
        [
          req.user!.id,
          contractId,
          {
            periodType:      data.periodType,
            periodLabel:     data.periodLabel,
            fiscalYear:      data.fiscalYear,
            costCategory:    data.costCategory,
            actualAmountAed: data.actualAmountAed,
            source:          data.source,
            referenceNo:     data.referenceNo,
            notes:           data.notes ?? null,
          },
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'contract_not_found', 'Contract not found or inactive');

      req.logger.info({
        action: 'fn_contract_cost_actual_record',
        userId: req.user?.id,
        contractId,
        costCategory: data.costCategory,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      // Return 201 for new creation; upsert returns the same shape for idempotent re-posts
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_contract_cost_actual_record',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // POST /api/v1/financial/budget-burn/variance/:contractId/draft-cure-notice
  // -------------------------------------------------------------------------
  draftCureNotice: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_draft_generate',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { contractId } = contractIdParamSchema.parse(req.params);
      // Body is optional — parse defensively
      const body = req.body !== undefined && req.body !== null ? req.body : {};
      const data = draftCureNoticeSchema.parse(body);

      const result = await generateBudgetCureNoticeDraft({
        contractId,
        actorId:         req.user!.id,
        tenantId:        req.tenantId ?? '',
        thresholdPct:    data.thresholdPct,
        focusPeriodLabel: data.focusPeriodLabel,
      });

      req.logger.info({
        action: 'fn_advisory_draft_generate',
        userId: req.user?.id,
        contractId,
        draftId: result.draftId,
        correlationId: result.correlationId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_draft_generate',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

};
