/**
 * Index-Linked Contracts — tenant-side resolved catalog reader (R-IL Phase B).
 *
 * Backs the FE Index-Linked Contracts module (renamed from "Trade Margin").
 * Returns the resolved catalog (industry rows ∪ tenant overrides) for the
 * current tenant. Drives all FE labels — display strings, units, slider
 * bounds, waterfall sort order, kicker text.
 *
 * Permission gate: finance.margin.read (same as the rest of the module).
 *
 *   GET /api/v1/index-linked/catalog/benchmarks
 *   GET /api/v1/index-linked/catalog/cost-components
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

export const indexLinkedCatalogController = {

  benchmarks: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_catalog_benchmarks_for_current_tenant', userId: req.user?.id });
    try {
      const result = await db.callFunction(
        'fn_catalog_benchmarks_for_current_tenant',
        [],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_catalog_benchmarks_for_current_tenant', duration: Date.now() - startTime, statusCode: 200 });
      res.json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_catalog_benchmarks_for_current_tenant', errorType: (e as Error).name });
      next(e);
    }
  },

  costComponents: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_catalog_cost_components_for_current_tenant', userId: req.user?.id });
    try {
      const result = await db.callFunction(
        'fn_catalog_cost_components_for_current_tenant',
        [],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_catalog_cost_components_for_current_tenant', duration: Date.now() - startTime, statusCode: 200 });
      res.json(result);
    } catch (e) {
      req.logger.error({ action: 'fn_catalog_cost_components_for_current_tenant', errorType: (e as Error).name });
      next(e);
    }
  },
};
