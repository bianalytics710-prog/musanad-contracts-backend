/**
 * Role controller — list active roles.
 *
 * GET /api/v1/roles → fn_role_list(p_page, p_limit)
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import type { ListRolesQueryInput } from '../schemas/user.schemas';
import type { RoleListResponse } from '../types/api.types';

export const roleController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'role.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const q = req.query as unknown as ListRolesQueryInput;
      const result = await db.callFunction<RoleListResponse>(
        'fn_role_list',
        [q.page ?? 1, q.limit ?? 50],
        { actorId: req.user!.id },
      );

      req.logger.info(
        { action: 'role.list', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'role.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType:
            error instanceof ApiError ? error.code : error instanceof Error ? error.name : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },
};
