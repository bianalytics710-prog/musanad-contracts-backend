/**
 * CR-M — Party Workforce controller.
 *
 * Thin controller: Pino entry/exit log → Zod validate → db.callFunction() → response.
 * No business logic. Endpoints:
 *   POST /api/v1/parties/:partyId/workforce  (fn_party_workforce_set)
 *   GET  /api/v1/parties/:partyId/workforce  (fn_party_workforce_get)
 *   GET  /api/v1/parties/workforce           (fn_party_workforce_list)
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import {
  setPartyWorkforceSchema,
  partyWorkforceListQuerySchema,
} from '../schemas/regulatory-cascade.schemas';

export const partyWorkforceController = {

  set: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_party_workforce_set',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const partyId = parseInt(req.params.partyId ?? '', 10);
      if (isNaN(partyId) || partyId <= 0) throw new ApiError(400, 'invalid_id', 'Invalid partyId format');

      const data = setPartyWorkforceSchema.parse(req.body);

      const result = await db.callFunction('fn_party_workforce_set', [
        req.user!.id,
        partyId,
        {
          headcount: data.headcount,
          emiratisationTarget: data.emiratisationTarget,
          emiratisationActual: data.emiratisationActual,
          ...(data.category !== undefined ? { category: data.category } : {}),
          ...(data.notes !== undefined && data.notes !== null ? { notes: data.notes } : {}),
        },
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'party_not_found', 'Party not found');

      req.logger.info({
        action: 'fn_party_workforce_set',
        userId: req.user?.id,
        partyId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_party_workforce_set',
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
      action: 'fn_party_workforce_get',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const partyId = parseInt(req.params.partyId ?? '', 10);
      if (isNaN(partyId) || partyId <= 0) throw new ApiError(400, 'invalid_id', 'Invalid partyId format');

      const result = await db.callFunction('fn_party_workforce_get', [
        req.user!.id,
        partyId,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'workforce_not_found', 'No active workforce row for this party');

      req.logger.info({
        action: 'fn_party_workforce_get',
        userId: req.user?.id,
        partyId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_party_workforce_get',
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
      action: 'fn_party_workforce_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = partyWorkforceListQuerySchema.parse(req.query);

      const result = await db.callFunction('fn_party_workforce_list', [
        req.user!.id,
        params.band ?? null,
        params.compliant ?? null,
        params.search ?? null,
        params.limit,
        params.offset,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_party_workforce_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_party_workforce_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

};
