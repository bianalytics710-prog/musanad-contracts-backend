/**
 * CR-O — Oil-Trade Margin routes.
 *
 * Two separate route sub-trees under /api/v1/financial/:
 *   /trade-margin/*      — trade position + margin compute/aggregate/history endpoints
 *   /price-benchmarks/*  — benchmark series list + record + recompute endpoints
 *
 * Mount in v1/index.ts:
 *   v1Router.use('/financial/trade-margin', tradeMarginRouter);
 *   v1Router.use('/financial/price-benchmarks', priceBenchmarksRouter);
 *
 * CRITICAL (CR-M DEFECT-CRM-ROUTES-1 lesson):
 *   Every route MUST include rlsMiddleware between authenticate and authorise so the
 *   tenant GUC (app.current_tenant_id, app.current_user_id) is set before fn_ calls.
 *
 * Route ordering (critical — literals before parameterised):
 *   tradeMarginRouter:    /aggregate  BEFORE  /:positionId
 *                         /:positionId/history  (no literal conflict here — nested sub-path)
 *   priceBenchmarksRouter: /recompute  BEFORE  POST / (different method — but explicit is safer)
 *
 * Permissions (from contracts.md):
 *   finance.margin.read  → positions list, position detail, snapshot history, aggregate, benchmark list
 *   finance.trade.manage → price-benchmarks/recompute, price-benchmarks record
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { validate } from '../../middleware/validation.middleware';
import { financialTradeMarginController } from '../../controllers/financial-trade-margin.controller';
import {
  tradePositionListQuerySchema,
  marginAggregateQuerySchema,
  marginSnapshotHistoryQuerySchema,
  priceBenchmarkListQuerySchema,
  recomputePriceBenchmarkSchema,
  recordPriceBenchmarkSchema,
} from '../../schemas/trade-margin.schemas';

// ============================================================================
// tradeMarginRouter — mounted at /api/v1/financial/trade-margin
// ============================================================================
export const tradeMarginRouter = Router();

// ---------------------------------------------------------------------------
// Literal-path routes (MUST come before /:positionId)
// ---------------------------------------------------------------------------

// GET /api/v1/financial/trade-margin — positions list
tradeMarginRouter.get(
  '/',
  authenticate,
  rlsMiddleware,
  authorise(['finance.margin.read']),
  validate(tradePositionListQuerySchema, 'query'),
  financialTradeMarginController.listPositions,
);

// GET /api/v1/financial/trade-margin/aggregate — CFO/trading-desk portfolio rollup
// MUST be before /:positionId to prevent Express matching 'aggregate' as positionId
tradeMarginRouter.get(
  '/aggregate',
  authenticate,
  rlsMiddleware,
  authorise(['finance.margin.read']),
  validate(marginAggregateQuerySchema, 'query'),
  financialTradeMarginController.getAggregate,
);

// ---------------------------------------------------------------------------
// Parameterised routes (/:positionId and sub-routes)
// ---------------------------------------------------------------------------

// GET /api/v1/financial/trade-margin/:positionId — position detail (fn_trade_position_get)
tradeMarginRouter.get(
  '/:positionId',
  authenticate,
  rlsMiddleware,
  authorise(['finance.margin.read']),
  financialTradeMarginController.getPositionDetail,
);

// GET /api/v1/financial/trade-margin/:positionId/history — snapshot history
tradeMarginRouter.get(
  '/:positionId/history',
  authenticate,
  rlsMiddleware,
  authorise(['finance.margin.read']),
  validate(marginSnapshotHistoryQuerySchema, 'query'),
  financialTradeMarginController.getSnapshotHistory,
);

// ============================================================================
// priceBenchmarksRouter — mounted at /api/v1/financial/price-benchmarks
// ============================================================================
export const priceBenchmarksRouter = Router();

// ---------------------------------------------------------------------------
// Literal-path routes (MUST come before parameterised, and /recompute before POST /)
// ---------------------------------------------------------------------------

// GET /api/v1/financial/price-benchmarks — benchmark series list
priceBenchmarksRouter.get(
  '/',
  authenticate,
  rlsMiddleware,
  authorise(['finance.margin.read']),
  validate(priceBenchmarkListQuerySchema, 'query'),
  financialTradeMarginController.listBenchmarks,
);

// POST /api/v1/financial/price-benchmarks/recompute — OSP-drop demo action
// MUST be registered BEFORE POST / (both are POST but different paths)
priceBenchmarksRouter.post(
  '/recompute',
  authenticate,
  rlsMiddleware,
  authorise(['finance.trade.manage']),
  validate(recomputePriceBenchmarkSchema, 'body'),
  financialTradeMarginController.recomputeByPrice,
);

// POST /api/v1/financial/price-benchmarks — record / upsert benchmark
priceBenchmarksRouter.post(
  '/',
  authenticate,
  rlsMiddleware,
  authorise(['finance.trade.manage']),
  validate(recordPriceBenchmarkSchema, 'body'),
  financialTradeMarginController.recordBenchmark,
);

export default tradeMarginRouter;
