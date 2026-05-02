/**
 * Permission controller — list permission catalog.
 *
 * GET /api/v1/permissions → fn_permission_list(p_page, p_limit, p_role_id)
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import type { ListPermissionsQueryInput } from '../schemas/user.schemas';
import type { PermissionListResponse } from '../types/api.types';

export const permissionController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'permission.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const q = req.query as unknown as ListPermissionsQueryInput;
      const result = await db.callFunction<PermissionListResponse>(
        'fn_permission_list',
        [q.page ?? 1, q.limit ?? 50, q.roleId ?? null],
        { actorId: req.user!.id },
      );

      req.logger.info(
        {
          action: 'permission.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'permission.list',
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
