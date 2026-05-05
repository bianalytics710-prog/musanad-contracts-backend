/**
 * Regulatory controllers — M5 Regulatory Radar (15 endpoints).
 *
 * Each method is a thin HTTP layer over a single fn_ call routed through
 * src/services/regulatory.service.ts. No business logic in this file.
 *
 *   regulationsController       — 5 endpoints (S1..S5)
 *   regulatoryUpdatesController — 5 endpoints (S6..S10)
 *   regulatoryImpactsController — 3 endpoints (S11/S12/S13)
 *   impactCategoriesController  — 2 endpoints (S14/S15)
 *
 * Logging contract (BP-04 + BE template in skill-logging-patterns.md):
 *   - req.logger.info on entry with action, userId, method, path
 *   - req.logger.info on exit with action, userId, duration, statusCode
 *   - req.logger.error in catch with action, userId, duration, errorType
 *   - sensitive fields NEVER appear in log lines (req.body never logged
 *     directly; pino redaction in logger.util.ts is the safety net for
 *     impactPayload + summaryEn etc.)
 *
 * Polymorphic permission (W2 — QA Stage 3):
 *   ep_regulatory_impact_resolve relies on the fn body's OR-branch
 *   (regulations.manage OR drafted_by = current_user). The controller
 *   pre-gates with a broad authoriseAnyOf at the route layer (so a caller
 *   with NO relevant permission gets a clean 403 before reaching the DB)
 *   and the fn raises 42501 if the per-row OR-branch fails. The
 *   translatePgError mapping converts 42501 → 403 with the structured
 *   message preserved.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, NotFoundError } from '../utils/errors.util';
import * as regulatoryService from '../services/regulatory.service';
import type {
  BulkDetectRegulatoryImpactInput,
  CreateRegulationInput,
  CreateRegulatoryUpdateInput,
  ImpactCategoryListQueryInput,
  RegulationListQueryInput,
  RegulatoryIdParamInput,
  RegulatoryImpactListQueryInput,
  RegulatoryUpdateListQueryInput,
  ResolveRegulatoryImpactInput,
  UpdateRegulationInput,
  UpdateRegulatoryUpdateInput,
  UpsertImpactCategoryInput,
} from '../schemas/regulatory.schemas';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

// ============================================================
// 1. Regulation library (S1–S5)
// ============================================================
export const regulationsController = {
  /** GET /api/v1/regulations → fn_regulation_list (S1). */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'regulation.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as RegulationListQueryInput;
      const result = await regulatoryService.listRegulations(req.user!.id, {
        page: q.page,
        limit: q.limit,
        jurisdiction: q.jurisdiction,
        regulationType: q.regulationType,
        issuerId: q.issuerId,
        status: q.status,
        search: q.search,
      });
      req.logger.info(
        {
          action: 'regulation.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resultCount: result?.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulation.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** GET /api/v1/regulations/:id → fn_regulation_get_by_id (S2). */
  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'regulation.getById', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as RegulatoryIdParamInput;
      const result = await regulatoryService.getRegulationById(req.user!.id, id);
      if (!result) {
        throw new NotFoundError('Regulation not found', { id: 'Regulation not found' });
      }
      req.logger.info(
        {
          action: 'regulation.getById',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulation.getById',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** POST /api/v1/regulations → fn_regulation_create (S3). */
  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'regulation.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const body = req.body as CreateRegulationInput;
      const result = await regulatoryService.createRegulation(req.user!.id, body);
      req.logger.info(
        {
          action: 'regulation.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulation.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** PATCH /api/v1/regulations/:id → fn_regulation_update (S4). */
  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'regulation.update', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as RegulatoryIdParamInput;
      const body = req.body as UpdateRegulationInput;
      const result = await regulatoryService.updateRegulation(req.user!.id, id, body);
      req.logger.info(
        {
          action: 'regulation.update',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulation.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** DELETE /api/v1/regulations/:id → fn_regulation_delete (S5). */
  async delete(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'regulation.delete', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as RegulatoryIdParamInput;
      const result = await regulatoryService.deleteRegulation(req.user!.id, id);
      req.logger.info(
        {
          action: 'regulation.delete',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulation.delete',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },
};

// ============================================================
// 2. Regulatory updates (S6–S10)
// ============================================================
export const regulatoryUpdatesController = {
  /** GET /api/v1/regulatory-updates → fn_regulatory_update_list (S6). */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'regulatoryUpdate.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as RegulatoryUpdateListQueryInput;
      const result = await regulatoryService.listRegulatoryUpdates(req.user!.id, {
        page: q.page,
        limit: q.limit,
        regulatorId: q.regulatorId,
        severity: q.severity,
        categoryId: q.categoryId,
        effectiveFrom: q.effectiveFrom,
        effectiveTo: q.effectiveTo,
        complianceDeadlineMax: q.complianceDeadlineMax,
      });
      req.logger.info(
        {
          action: 'regulatoryUpdate.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resultCount: result?.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulatoryUpdate.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** GET /api/v1/regulatory-updates/:id → fn_regulatory_update_get_by_id (S7). */
  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'regulatoryUpdate.getById',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as RegulatoryIdParamInput;
      const result = await regulatoryService.getRegulatoryUpdateById(req.user!.id, id);
      if (!result) {
        throw new NotFoundError('Regulatory update not found', {
          id: 'Regulatory update not found',
        });
      }
      req.logger.info(
        {
          action: 'regulatoryUpdate.getById',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulatoryUpdate.getById',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** POST /api/v1/regulatory-updates → fn_regulatory_update_create (S8). */
  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'regulatoryUpdate.create',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const body = req.body as CreateRegulatoryUpdateInput;
      const result = await regulatoryService.createRegulatoryUpdate(req.user!.id, body);
      req.logger.info(
        {
          action: 'regulatoryUpdate.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulatoryUpdate.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** PATCH /api/v1/regulatory-updates/:id → fn_regulatory_update_update (S9). */
  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'regulatoryUpdate.update',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as RegulatoryIdParamInput;
      const body = req.body as UpdateRegulatoryUpdateInput;
      const result = await regulatoryService.updateRegulatoryUpdate(req.user!.id, id, body);
      req.logger.info(
        {
          action: 'regulatoryUpdate.update',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulatoryUpdate.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** DELETE /api/v1/regulatory-updates/:id → fn_regulatory_update_delete (S10). */
  async delete(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'regulatoryUpdate.delete',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as RegulatoryIdParamInput;
      const result = await regulatoryService.deleteRegulatoryUpdate(req.user!.id, id);
      req.logger.info(
        {
          action: 'regulatoryUpdate.delete',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
          cascadedImpacts: result?.cascadedImpacts ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulatoryUpdate.delete',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },
};

// ============================================================
// 3. Regulatory impacts (S11–S13)
// ============================================================
export const regulatoryImpactsController = {
  /**
   * POST /api/v1/regulatory-impacts/bulk-detect →
   * fn_regulatory_impact_create_bulk (S11).
   *
   * impactPayload is SENSITIVE — pino-redacted via SENSITIVE_PATHS in
   * logger.util.ts ('impactPayload' + 'req.body.impactPayload' + wildcard
   * variants) AND the inner per-contract noteEn/noteAr/summaryEn/summaryAr
   * (summaryEn already in the M4 list; noteEn/noteAr added by this module).
   */
  async bulkDetect(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'regulatoryImpact.bulkDetect',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const body = req.body as BulkDetectRegulatoryImpactInput;
      const result = await regulatoryService.bulkDetectRegulatoryImpacts(req.user!.id, body);
      req.logger.info(
        {
          action: 'regulatoryImpact.bulkDetect',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 201,
          createdCount: result?.createdCount ?? 0,
          skippedDuplicateCount: result?.skippedDuplicateCount ?? 0,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulatoryImpact.bulkDetect',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** GET /api/v1/regulatory-impacts → fn_regulatory_impact_list (S12). */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'regulatoryImpact.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as RegulatoryImpactListQueryInput;
      const result = await regulatoryService.listRegulatoryImpacts(req.user!.id, {
        page: q.page,
        limit: q.limit,
        contractId: q.contractId,
        regulationId: q.regulationId,
        regulatoryUpdateId: q.regulatoryUpdateId,
        resolved: q.resolved,
      });
      req.logger.info(
        {
          action: 'regulatoryImpact.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resultCount: result?.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulatoryImpact.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * PATCH /api/v1/regulatory-impacts/:id/resolve →
   * fn_regulatory_impact_resolve (S13).
   *
   * Polymorphic permission (W2): the route gate is broad (regulations.read
   * OR regulations.manage); the fn body enforces the precise OR-branch
   * (regulations.manage OR drafted_by = current_user). Non-drafters
   * without regulations.manage will receive 403 from the fn raise (mapped
   * via translatePgError 42501 → ForbiddenError).
   */
  async resolve(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'regulatoryImpact.resolve',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as RegulatoryIdParamInput;
      const body = req.body as ResolveRegulatoryImpactInput;
      const result = await regulatoryService.resolveRegulatoryImpact(req.user!.id, id, body);
      req.logger.info(
        {
          action: 'regulatoryImpact.resolve',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resolved: result?.resolved,
          resolutionAction: result?.resolutionAction,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'regulatoryImpact.resolve',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },
};

// ============================================================
// 4. Impact categories (S14–S15)
// ============================================================
export const impactCategoriesController = {
  /**
   * GET /api/v1/impact-categories → fn_impact_category_list (S14).
   *
   * AC-S14-05: any authenticated user (no permission gate beyond JWT).
   */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'impactCategory.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as ImpactCategoryListQueryInput;
      const result = await regulatoryService.listImpactCategories(
        req.user!.id,
        q.includeInactive,
      );
      req.logger.info(
        {
          action: 'impactCategory.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resultCount: result?.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'impactCategory.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * PUT /api/v1/impact-categories → fn_impact_category_upsert (S15).
   *
   * Single-call upsert keyed on `key`. Returns 200 for both create AND
   * update branches (AC-S15-01 / AC-S15-02; createdOrUpdated discriminator
   * in the body).
   */
  async upsert(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'impactCategory.upsert', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const body = req.body as UpsertImpactCategoryInput;
      const result = await regulatoryService.upsertImpactCategory(req.user!.id, body);
      req.logger.info(
        {
          action: 'impactCategory.upsert',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          createdOrUpdated: result?.createdOrUpdated,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'impactCategory.upsert',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },
};
