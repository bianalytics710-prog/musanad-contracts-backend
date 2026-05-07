/**
 * User controller. CRUD via fn_user_*.
 *
 * Per the M0 spec line 442 + api-contracts.json:
 *   - GET    /api/v1/users        — list (auth + user.read.all)
 *   - POST   /api/v1/users        — create (auth + user.manage)
 *   - GET    /api/v1/users/:id    — get (self OR user.read.all)
 *   - PUT    /api/v1/users/:id    — update (self for limited fields, OR user.manage)
 *   - DELETE /api/v1/users/:id    — soft delete (auth + user.manage)
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { hashPassword } from '../utils/password.util';
import {
  ApiError,
  ForbiddenError,
  NotFoundError,
  ValidationError,
} from '../utils/errors.util';
import type {
  CreateUserInput,
  ListUsersQueryInput,
  ResetPasswordInput,
  UpdateUserInput,
  UserIdParam,
} from '../schemas/user.schemas';
import type { User, UserListResponse } from '../types/api.types';

export const userController = {
  /**
   * GET /api/v1/users
   */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'user.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const q = req.query as unknown as ListUsersQueryInput;
      const result = await db.callFunction<UserListResponse>(
        'fn_user_list',
        [q.page ?? 1, q.limit ?? 20, q.search ?? null, q.roleId ?? null],
        { actorId: req.user!.id },
      );

      req.logger.info(
        { action: 'user.list', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'user.list',
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

  /**
   * POST /api/v1/users
   */
  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'user.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const body = req.body as CreateUserInput;
      // Hash plaintext password BEFORE the DB call. Plain password never
      // reaches the DB layer. Pino redact catches `*.password` in the
      // request body if it surfaces in any log line.
      const passwordHash = await hashPassword(body.password);

      const dbPayload = {
        email: body.email,
        passwordHash,
        firstName: body.firstName,
        lastName: body.lastName,
        roleId: body.roleId,
      };

      const result = await db.callFunction<User>('fn_user_create', [dbPayload, req.user!.id], {
        actorId: req.user!.id,
      });

      req.logger.info(
        {
          action: 'user.create',
          userId: req.user?.id,
          newUserId: result.id,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );

      res.status(201).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'user.create',
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

  /**
   * GET /api/v1/users/:id
   */
  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'user.getById', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const { id } = req.params as unknown as UserIdParam;
      const result = await db.callFunction<User | null>('fn_user_get_by_id', [id], {
        actorId: req.user!.id,
      });
      if (!result) {
        throw new NotFoundError('User not found');
      }

      req.logger.info(
        {
          action: 'user.getById',
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
          action: 'user.getById',
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

  /**
   * PUT /api/v1/users/:id
   */
  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'user.update', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const { id } = req.params as unknown as UserIdParam;
      const body = req.body as UpdateUserInput;
      const isSelf = id === req.user!.id;
      const hasManage = req.user!.permissions.includes('user.manage');

      // Self can only edit firstName/lastName. Email + roleId require user.manage.
      if (isSelf && !hasManage) {
        if ('email' in body || 'roleId' in body) {
          throw new ForbiddenError(
            'Self-update is restricted to firstName and lastName',
          );
        }
      } else if (!hasManage) {
        throw new ForbiddenError('Insufficient permissions');
      }

      const result = await db.callFunction<User | null>(
        'fn_user_update',
        [id, body, req.user!.id],
        { actorId: req.user!.id },
      );
      if (!result) {
        throw new NotFoundError('User not found');
      }

      req.logger.info(
        {
          action: 'user.update',
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
          action: 'user.update',
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

  /**
   * POST /api/v1/users/:id/reset-password (R-PA2 admin row action).
   * Plaintext is hashed with bcrypt(12) here so the DB never sees it.
   */
  async resetPassword(
    req: Request,
    res: Response,
    next: NextFunction,
  ): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'user.resetPassword', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const { id } = req.params as unknown as UserIdParam;
      const { password } = req.body as ResetPasswordInput;

      // Self-protection (mirrors fn_user_password_reset; surfaced earlier
      // here so the bcrypt hash never gets generated for a self-reset).
      if (id === req.user!.id) {
        throw new ValidationError(
          'Cannot reset your own password — use /auth/change-password',
        );
      }

      const passwordHash = await hashPassword(password);
      const result = await db.callFunction<{
        success: boolean;
        message: string;
        userId: number;
      }>('fn_user_password_reset', [id, passwordHash, req.user!.id], {
        actorId: req.user!.id,
      });

      req.logger.info(
        {
          action: 'user.resetPassword',
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
          action: 'user.resetPassword',
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

  /**
   * DELETE /api/v1/users/:id
   */
  async delete(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'user.delete', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const { id } = req.params as unknown as UserIdParam;

      // Self-protection
      if (id === req.user!.id) {
        throw new ValidationError('Cannot deactivate your own account');
      }

      const result = await db.callFunction<{ success: boolean; message: string }>(
        'fn_user_delete',
        [id, req.user!.id],
        { actorId: req.user!.id },
      );

      req.logger.info(
        {
          action: 'user.delete',
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
          action: 'user.delete',
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
