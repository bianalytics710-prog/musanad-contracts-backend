/**
 * CR-M — Regulatory Cascade controller.
 *
 * Thin controller: Pino entry/exit log → Zod validate → db.callFunction() → response.
 * For draft-amendment endpoint delegates to regulatory-cascade-draft.service.ts
 * which orchestrates the correlation → advisory-drafter → link seam.
 *
 * Pino redact: penaltyBasis and remediationNote are in the global SENSITIVE_PATHS
 * via logger.util.ts (to be added). Controllers never log response bodies.
 *
 * Endpoints:
 *   POST  /api/v1/regulatory/cascade/run               (fn_regulatory_cascade_run)
 *   GET   /api/v1/regulatory/cascade                   (fn_regulatory_cascade_list)
 *   GET   /api/v1/regulatory/cascade/:runId            (fn_regulatory_cascade_get)
 *   PATCH /api/v1/regulatory/cascade/items/:itemId/status  (fn_regulatory_cascade_item_set_status)
 *   POST  /api/v1/regulatory/cascade/items/:itemId/draft-amendment (service seam)
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import {
  runCascadeSchema,
  cascadeListQuerySchema,
  setRemediationStatusSchema,
  draftAmendmentSchema,
} from '../schemas/regulatory-cascade.schemas';
import { generateCascadeDraftAmendment } from '../services/regulatory-cascade-draft.service';

export const regulatoryCascadeController = {

  run: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_regulatory_cascade_run',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const data = runCascadeSchema.parse(req.body);
      // Normalise: accept either signalId or impactSignalId (backwards compat)
      const signalId = data.signalId ?? data.impactSignalId;
      if (signalId === undefined) {
        throw new ApiError(400, 'signal_id_required', 'signalId is required');
      }

      const result = await db.callFunction('fn_regulatory_cascade_run', [
        req.user!.id,
        signalId,
        data.params ?? {},
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'signal_not_found', 'Signal not found or not regulatory kind');

      req.logger.info({
        action: 'fn_regulatory_cascade_run',
        userId: req.user?.id,
        signalId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_regulatory_cascade_run',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  list: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_regulatory_cascade_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = cascadeListQuerySchema.parse(req.query);

      const result = await db.callFunction('fn_regulatory_cascade_list', [
        req.user!.id,
        params.signalId ?? null,
        params.limit,
        params.offset,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_regulatory_cascade_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_regulatory_cascade_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  get: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_regulatory_cascade_get',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const runId = parseInt(req.params.runId ?? '', 10);
      if (isNaN(runId) || runId <= 0) throw new ApiError(400, 'invalid_id', 'Invalid runId format');

      const result = await db.callFunction('fn_regulatory_cascade_get', [
        req.user!.id,
        runId,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'run_not_found', 'Cascade run not found');

      req.logger.info({
        action: 'fn_regulatory_cascade_get',
        userId: req.user?.id,
        runId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_regulatory_cascade_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  setItemStatus: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_regulatory_cascade_item_set_status',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const itemId = parseInt(req.params.itemId ?? '', 10);
      if (isNaN(itemId) || itemId <= 0) throw new ApiError(400, 'invalid_id', 'Invalid itemId format');

      const data = setRemediationStatusSchema.parse(req.body);

      const result = await db.callFunction('fn_regulatory_cascade_item_set_status', [
        req.user!.id,
        itemId,
        data.status,
        data.note ?? null,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'item_not_found', 'Cascade item not found');

      req.logger.info({
        action: 'fn_regulatory_cascade_item_set_status',
        userId: req.user?.id,
        itemId,
        status: data.status,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_regulatory_cascade_item_set_status',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  draftAmendment: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_regulatory_cascade_item_link_draft',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const itemId = parseInt(req.params.itemId ?? '', 10);
      if (isNaN(itemId) || itemId <= 0) throw new ApiError(400, 'invalid_id', 'Invalid itemId format');

      // Body is optional per contracts.md — parse defensively
      const body = req.body !== undefined && req.body !== null ? req.body : {};
      const data = draftAmendmentSchema.parse(body);

      const result = await generateCascadeDraftAmendment({
        itemId,
        contractId: data.contractId,
        actorId: req.user!.id,
        tenantId: req.tenantId ?? '',
      });

      req.logger.info({
        action: 'fn_regulatory_cascade_item_link_draft',
        userId: req.user?.id,
        itemId,
        draftId: result.draftId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_regulatory_cascade_item_link_draft',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

};
