/**
 * Industry-catalog controller — R-IL Phase B (mig 571 backed).
 *
 * Backs the /app/admin/industry-catalogs Platform Admin pages. Thin
 * pass-through over the fn_industry_list + 6 fn_catalog_* fns from
 * migration 571.
 *
 * All endpoints require platform.catalog.manage (route-layer authorise() +
 * fn body's own in-body check — defense in depth).
 *
 *   GET    /api/v1/admin/industry-catalogs                            fn_industry_list
 *   GET    /api/v1/admin/industry-catalogs/:industryId/benchmarks     fn_catalog_benchmark_list
 *   POST   /api/v1/admin/industry-catalogs/:industryId/benchmarks     fn_catalog_benchmark_upsert (id=NULL)
 *   PUT    /api/v1/admin/industry-catalogs/benchmarks/:id             fn_catalog_benchmark_upsert
 *   DELETE /api/v1/admin/industry-catalogs/benchmarks/:id             fn_catalog_benchmark_deactivate
 *   GET    /api/v1/admin/industry-catalogs/:industryId/cost-components fn_catalog_cost_component_list
 *   POST   /api/v1/admin/industry-catalogs/:industryId/cost-components fn_catalog_cost_component_upsert (id=NULL)
 *   PUT    /api/v1/admin/industry-catalogs/cost-components/:id         fn_catalog_cost_component_upsert
 *   DELETE /api/v1/admin/industry-catalogs/cost-components/:id         fn_catalog_cost_component_deactivate
 *
 * Tenant overrides reuse the same upsert fn with tenantId set instead of
 * industryId; the optional ?tenantId= query param on list endpoints
 * switches the scope.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

interface BenchmarkInput {
  industryId?: number | null;
  tenantId?: string | null;
  code: string;
  displayLabelEn: string;
  displayLabelAr?: string | null;
  unitLabel: string;
  volumeUnitLabel: string;
  typicalLow?: number | null;
  typicalHigh?: number | null;
  kickerText?: string | null;
  isFx?: boolean;
  sortOrder?: number;
}

interface CostComponentInput {
  industryId?: number | null;
  tenantId?: string | null;
  code: string;
  displayLabelEn: string;
  displayLabelAr?: string | null;
  sign: '+' | '-';
  isRevenue?: boolean;
  sortOrder?: number;
  description?: string | null;
}

function readBenchmark(req: Request): BenchmarkInput {
  const b = req.body as Record<string, unknown>;
  return {
    industryId: typeof b.industryId === 'number' ? b.industryId : null,
    tenantId: typeof b.tenantId === 'string' ? b.tenantId : null,
    code: String(b.code),
    displayLabelEn: String(b.displayLabelEn),
    displayLabelAr: typeof b.displayLabelAr === 'string' ? b.displayLabelAr : null,
    unitLabel: String(b.unitLabel),
    volumeUnitLabel: String(b.volumeUnitLabel),
    typicalLow: typeof b.typicalLow === 'number' ? b.typicalLow : null,
    typicalHigh: typeof b.typicalHigh === 'number' ? b.typicalHigh : null,
    kickerText: typeof b.kickerText === 'string' ? b.kickerText : null,
    isFx: typeof b.isFx === 'boolean' ? b.isFx : false,
    sortOrder: typeof b.sortOrder === 'number' ? b.sortOrder : 100,
  };
}

function readCostComponent(req: Request): CostComponentInput {
  const b = req.body as Record<string, unknown>;
  return {
    industryId: typeof b.industryId === 'number' ? b.industryId : null,
    tenantId: typeof b.tenantId === 'string' ? b.tenantId : null,
    code: String(b.code),
    displayLabelEn: String(b.displayLabelEn),
    displayLabelAr: typeof b.displayLabelAr === 'string' ? b.displayLabelAr : null,
    sign: (b.sign === '+' || b.sign === '-') ? b.sign : '-',
    isRevenue: typeof b.isRevenue === 'boolean' ? b.isRevenue : false,
    sortOrder: typeof b.sortOrder === 'number' ? b.sortOrder : 100,
    description: typeof b.description === 'string' ? b.description : null,
  };
}

export const industryCatalogController = {

  // ---------------------------------------------------------------------------
  // POST /api/v1/admin/industry-catalogs       (create industry)
  // PUT  /api/v1/admin/industry-catalogs/:id   (update industry)
  // ---------------------------------------------------------------------------
  upsertIndustry: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const isCreate = req.method === 'POST';
    const id = isCreate ? null : Number(req.params.id);
    req.logger.info({ action: 'fn_industry_upsert', userId: req.user?.id, id });
    try {
      const b = req.body as Record<string, unknown>;
      const result = await db.callFunction(
        'fn_industry_upsert',
        [
          id,
          typeof b.code === 'string' ? b.code : '',
          typeof b.displayLabelEn === 'string' ? b.displayLabelEn : '',
          typeof b.displayLabelAr === 'string' ? b.displayLabelAr : null,
          typeof b.description === 'string' ? b.description : null,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_industry_upsert', duration: Date.now() - startTime, statusCode: isCreate ? 201 : 200 });
      res.status(isCreate ? 201 : 200).json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_industry_upsert', errorType: (e as Error).name });
      next(e);
    }
  },

  // ---------------------------------------------------------------------------
  // DELETE /api/v1/admin/industry-catalogs/:id (soft-delete; blocks if tenants linked)
  // ---------------------------------------------------------------------------
  deactivateIndustry: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const id = Number(req.params.id);
    req.logger.info({ action: 'fn_industry_deactivate', userId: req.user?.id, id });
    try {
      const result = await db.callFunction(
        'fn_industry_deactivate',
        [id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_industry_deactivate', duration: Date.now() - startTime, statusCode: 200 });
      res.json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_industry_deactivate', errorType: (e as Error).name });
      next(e);
    }
  },

  // ---------------------------------------------------------------------------
  // GET /api/v1/admin/industry-catalogs
  // ---------------------------------------------------------------------------
  listIndustries: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_industry_list', userId: req.user?.id });
    try {
      const result = await db.callFunction('fn_industry_list', [], {
        actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID,
      });
      req.logger.info({ action: 'fn_industry_list', duration: Date.now() - startTime, statusCode: 200 });
      res.json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_industry_list', errorType: (e as Error).name });
      next(e);
    }
  },

  // ---------------------------------------------------------------------------
  // GET /api/v1/admin/industry-catalogs/:industryId/benchmarks
  //     ?tenantId=<uuid> switches scope to tenant-override view
  // ---------------------------------------------------------------------------
  listBenchmarks: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const industryId = req.params.industryId ? Number(req.params.industryId) : null;
    const tenantId = typeof req.query.tenantId === 'string' ? req.query.tenantId : null;
    req.logger.info({ action: 'fn_catalog_benchmark_list', userId: req.user?.id, industryId, tenantId });
    try {
      const result = await db.callFunction(
        'fn_catalog_benchmark_list',
        [industryId, tenantId],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_catalog_benchmark_list', duration: Date.now() - startTime, statusCode: 200 });
      res.json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_catalog_benchmark_list', errorType: (e as Error).name });
      next(e);
    }
  },

  // ---------------------------------------------------------------------------
  // POST /api/v1/admin/industry-catalogs/:industryId/benchmarks  (create)
  // PUT  /api/v1/admin/industry-catalogs/benchmarks/:id           (update)
  // ---------------------------------------------------------------------------
  upsertBenchmark: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const isCreate = req.method === 'POST';
    const id = isCreate ? null : Number(req.params.id);
    const industryIdFromRoute = req.params.industryId ? Number(req.params.industryId) : null;
    req.logger.info({ action: 'fn_catalog_benchmark_upsert', userId: req.user?.id, id });
    try {
      const i = readBenchmark(req);
      // On create, route param wins for industryId so it's URL-anchored;
      // on update, allow body to dictate (tenant overrides may flip scope).
      const industryId = isCreate ? industryIdFromRoute : (i.industryId ?? null);
      const tenantId = i.tenantId ?? null;
      const result = await db.callFunction(
        'fn_catalog_benchmark_upsert',
        [
          id,
          industryId,
          tenantId,
          i.code,
          i.displayLabelEn,
          i.displayLabelAr,
          i.unitLabel,
          i.volumeUnitLabel,
          i.typicalLow,
          i.typicalHigh,
          i.kickerText,
          i.isFx ?? false,
          i.sortOrder ?? 100,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_catalog_benchmark_upsert', duration: Date.now() - startTime, statusCode: isCreate ? 201 : 200 });
      res.status(isCreate ? 201 : 200).json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_catalog_benchmark_upsert', errorType: (e as Error).name });
      next(e);
    }
  },

  // ---------------------------------------------------------------------------
  // DELETE /api/v1/admin/industry-catalogs/benchmarks/:id (soft-delete)
  // ---------------------------------------------------------------------------
  deactivateBenchmark: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const id = Number(req.params.id);
    req.logger.info({ action: 'fn_catalog_benchmark_deactivate', userId: req.user?.id, id });
    try {
      const result = await db.callFunction(
        'fn_catalog_benchmark_deactivate',
        [id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_catalog_benchmark_deactivate', duration: Date.now() - startTime, statusCode: 200 });
      res.json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_catalog_benchmark_deactivate', errorType: (e as Error).name });
      next(e);
    }
  },

  // ---------------------------------------------------------------------------
  // GET /api/v1/admin/industry-catalogs/:industryId/cost-components
  // ---------------------------------------------------------------------------
  listCostComponents: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const industryId = req.params.industryId ? Number(req.params.industryId) : null;
    const tenantId = typeof req.query.tenantId === 'string' ? req.query.tenantId : null;
    req.logger.info({ action: 'fn_catalog_cost_component_list', userId: req.user?.id, industryId, tenantId });
    try {
      const result = await db.callFunction(
        'fn_catalog_cost_component_list',
        [industryId, tenantId],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_catalog_cost_component_list', duration: Date.now() - startTime, statusCode: 200 });
      res.json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_catalog_cost_component_list', errorType: (e as Error).name });
      next(e);
    }
  },

  // ---------------------------------------------------------------------------
  // POST /api/v1/admin/industry-catalogs/:industryId/cost-components (create)
  // PUT  /api/v1/admin/industry-catalogs/cost-components/:id          (update)
  // ---------------------------------------------------------------------------
  upsertCostComponent: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const isCreate = req.method === 'POST';
    const id = isCreate ? null : Number(req.params.id);
    const industryIdFromRoute = req.params.industryId ? Number(req.params.industryId) : null;
    req.logger.info({ action: 'fn_catalog_cost_component_upsert', userId: req.user?.id, id });
    try {
      const i = readCostComponent(req);
      const industryId = isCreate ? industryIdFromRoute : (i.industryId ?? null);
      const tenantId = i.tenantId ?? null;
      const result = await db.callFunction(
        'fn_catalog_cost_component_upsert',
        [
          id,
          industryId,
          tenantId,
          i.code,
          i.displayLabelEn,
          i.displayLabelAr,
          i.sign,
          i.isRevenue ?? false,
          i.sortOrder ?? 100,
          i.description,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_catalog_cost_component_upsert', duration: Date.now() - startTime, statusCode: isCreate ? 201 : 200 });
      res.status(isCreate ? 201 : 200).json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_catalog_cost_component_upsert', errorType: (e as Error).name });
      next(e);
    }
  },

  // ---------------------------------------------------------------------------
  // DELETE /api/v1/admin/industry-catalogs/cost-components/:id
  // ---------------------------------------------------------------------------
  deactivateCostComponent: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const id = Number(req.params.id);
    req.logger.info({ action: 'fn_catalog_cost_component_deactivate', userId: req.user?.id, id });
    try {
      const result = await db.callFunction(
        'fn_catalog_cost_component_deactivate',
        [id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_catalog_cost_component_deactivate', duration: Date.now() - startTime, statusCode: 200 });
      res.json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_catalog_cost_component_deactivate', errorType: (e as Error).name });
      next(e);
    }
  },
};
