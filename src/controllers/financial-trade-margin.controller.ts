/**
 * CR-O — Oil-Trade Margin controller.
 *
 * Thin controller: Pino entry/exit log → Zod validate → db.callFunction() → response.
 *
 * JSONB envelope: fn_ functions return JSONB objects directly (not wrapped in
 * { success, data }). Controllers return the raw fn_ result via res.json() —
 * same pattern as financial-budget-burn.controller.ts (CR-N).
 *
 * NULL handling per fn_ specs:
 *   fn_trade_position_list          → never NULL (empty data array)
 *   fn_trade_position_get           → NULL if not found / inactive → 404
 *   fn_margin_snapshot_history      → never NULL (count:0, snapshots:[]) when position exists
 *   fn_margin_aggregate             → never NULL (zero totals + empty breakdown)
 *   fn_price_benchmark_list         → never NULL (empty data array)
 *   fn_margin_recompute_for_price_change → never NULL (aggregate delta result)
 *   fn_price_benchmark_record       → always returns the upserted row
 *
 * Money fields: NUMERIC returned as ::text (string) by all fn_'s.
 * No coercion to number — preserve string on the wire (contracts.md DESIGN NOTE 1).
 *
 * Endpoints:
 *   GET  /api/v1/financial/trade-margin                         (positions list)
 *   GET  /api/v1/financial/trade-margin/aggregate               (portfolio rollup — STATIC before :positionId)
 *   GET  /api/v1/financial/price-benchmarks                     (benchmark series list)
 *   POST /api/v1/financial/price-benchmarks/recompute           (OSP-drop demo — STATIC before :positionId)
 *   POST /api/v1/financial/price-benchmarks                     (record benchmark)
 *   GET  /api/v1/financial/trade-margin/:positionId             (position detail)
 *   GET  /api/v1/financial/trade-margin/:positionId/history     (snapshot history)
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import {
  tradePositionListQuerySchema,
  marginAggregateQuerySchema,
  marginSnapshotHistoryQuerySchema,
  priceBenchmarkListQuerySchema,
  recomputePriceBenchmarkSchema,
  recordPriceBenchmarkSchema,
  positionIdParamSchema,
} from '../schemas/trade-margin.schemas';

export const financialTradeMarginController = {

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/trade-margin  (positions list)
  // -------------------------------------------------------------------------
  listPositions: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_trade_position_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = tradePositionListQuerySchema.parse(req.query);

      const result = await db.callFunction(
        'fn_trade_position_list',
        [
          req.user!.id,
          params.side    ?? null,
          params.grade   ?? null,
          params.status  ?? null,
          params.search  ?? null,
          params.page,
          params.limit,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_trade_position_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_trade_position_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/trade-margin/aggregate  (portfolio rollup)
  // IMPORTANT: Must be registered BEFORE /:positionId in routes to avoid
  // Express matching 'aggregate' as a positionId param.
  // -------------------------------------------------------------------------
  getAggregate: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_margin_aggregate',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = marginAggregateQuerySchema.parse(req.query);

      const filters = { groupBy: params.groupBy };

      const result = await db.callFunction(
        'fn_margin_aggregate',
        [req.user!.id, filters],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_margin_aggregate',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_margin_aggregate',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/trade-margin/:positionId  (position detail)
  // Uses fn_trade_position_get (returns full detail + latestMargin block from MV).
  // Note: fn_margin_compute is the WRITE path (inserts a new snapshot);
  //       this detail endpoint reads the latest snapshot via fn_trade_position_get.
  // -------------------------------------------------------------------------
  getPositionDetail: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_trade_position_get',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { positionId } = positionIdParamSchema.parse(req.params);

      const result = await db.callFunction(
        'fn_trade_position_get',
        [req.user!.id, positionId],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'position_not_found', 'Trade position not found or inactive');

      req.logger.info({
        action: 'fn_trade_position_get',
        userId: req.user?.id,
        positionId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_trade_position_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/trade-margin/:positionId/history  (snapshot history)
  // -------------------------------------------------------------------------
  getSnapshotHistory: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_margin_snapshot_history',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { positionId } = positionIdParamSchema.parse(req.params);
      const query = marginSnapshotHistoryQuerySchema.parse(req.query);

      const result = await db.callFunction(
        'fn_margin_snapshot_history',
        [req.user!.id, positionId, query.limit],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_margin_snapshot_history',
        userId: req.user?.id,
        positionId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_margin_snapshot_history',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // GET /api/v1/financial/price-benchmarks  (benchmark series list)
  // -------------------------------------------------------------------------
  listBenchmarks: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_price_benchmark_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = priceBenchmarkListQuerySchema.parse(req.query);

      const result = await db.callFunction(
        'fn_price_benchmark_list',
        [
          req.user!.id,
          params.benchmarkCode ?? null,
          params.from          ?? null,
          params.to            ?? null,
          params.page,
          params.limit,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_price_benchmark_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_price_benchmark_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // POST /api/v1/financial/price-benchmarks/recompute
  // The OSP-drop demo action: set new benchmark price → recompute all open forward positions.
  // IMPORTANT: Must be registered BEFORE POST /price-benchmarks in routes.
  // -------------------------------------------------------------------------
  recomputeByPrice: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_margin_recompute_for_price_change',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const data = recomputePriceBenchmarkSchema.parse(req.body);

      const result = await db.callFunction(
        'fn_margin_recompute_for_price_change',
        [
          req.user!.id,
          data.benchmarkCode,
          data.newPrice,
          data.priceDate ?? null,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_margin_recompute_for_price_change',
        userId: req.user?.id,
        benchmarkCode: data.benchmarkCode,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_margin_recompute_for_price_change',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // -------------------------------------------------------------------------
  // POST /api/v1/financial/price-benchmarks  (record / upsert benchmark)
  // -------------------------------------------------------------------------
  recordBenchmark: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_price_benchmark_record',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const data = recordPriceBenchmarkSchema.parse(req.body);

      const result = await db.callFunction(
        'fn_price_benchmark_record',
        [
          req.user!.id,
          {
            benchmarkCode: data.benchmarkCode,
            priceDate:     data.priceDate,
            priceValue:    data.priceValue,
            unit:          data.unit,
            periodGrain:   data.periodGrain,
            source:        data.source,
            notes:         data.notes ?? null,
          },
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'benchmark_not_found', 'Benchmark record not found after upsert');

      req.logger.info({
        action: 'fn_price_benchmark_record',
        userId: req.user?.id,
        benchmarkCode: data.benchmarkCode,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      // Upsert semantics — return 201 for both create and update (consistent with CR-N cost-actual pattern)
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_price_benchmark_record',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

};
