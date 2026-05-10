/**
 * CR-C — Admin Roles & Permissions Editor Controller (S15, S16).
 *
 *   POST   /api/v1/admin/roles                          → fn_role_create
 *   PATCH  /api/v1/admin/roles/:id                      → fn_role_update
 *   DELETE /api/v1/admin/roles/:id                      → fn_role_delete
 *   POST   /api/v1/admin/roles/:id/permissions/:permId/grant   → fn_role_permission_grant
 *   DELETE /api/v1/admin/roles/:id/permissions/:permId/revoke  → fn_role_permission_revoke
 *
 * Permission gate: role.manage at route layer + fn body. Built-in role
 * protection (8-name array per OPEN-DECISION-E) enforced at fn body —
 * P0001 'cannot_rename_system_role' / 'cannot_delete_system_role' /
 * 'cannot_revoke_system_grant' bubbles up via translatePgError → 422.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, UnprocessableEntityError } from '../../utils/errors.util';
import * as svc from '../../services/admin-roles-mgmt.service';
import type {
  CreateRoleBodyInferred,
  RoleIdParamInferred,
  RolePermissionParamsInferred,
  UpdateRoleBodyInferred,
} from '../../schemas/admin-roles-mgmt.schemas';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

/**
 * P0001 'cannot_*_system_*' messages from the fn raises map to 422 in this
 * codebase via translatePgError → ConflictError (409). Re-route in the catch
 * block below so the FE gets the contract-specified 422 envelope.
 */
const ERR_REMAP_TO_422 = new Set([
  'cannot_rename_system_role',
  'cannot_delete_system_role',
  'cannot_revoke_system_grant',
  'role_in_use',
]);

const remap = (err: unknown): unknown => {
  if (err instanceof ApiError && err.statusCode === 409) {
    const m = err.message ?? '';
    for (const tag of ERR_REMAP_TO_422) {
      if (m.includes(tag)) {
        return new UnprocessableEntityError(m, err.fields);
      }
    }
  }
  return err;
};

export const adminRolesMgmtController = {
  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.rolesMgmt.create',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const body = req.body as CreateRoleBodyInferred;
      const result = await svc.createRole(req.user!.id, {
        name: body.name,
        ...(body.description !== undefined ? { description: body.description } : {}),
      });
      req.logger.info(
        {
          action: 'admin.rolesMgmt.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 201,
          roleId: result?.id,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.rolesMgmt.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.rolesMgmt.update',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const params = req.params as unknown as RoleIdParamInferred;
      const body = req.body as UpdateRoleBodyInferred;
      const result = await svc.updateRole(req.user!.id, params.id, {
        ...(body.name !== undefined ? { name: body.name } : {}),
        ...(body.description !== undefined ? { description: body.description } : {}),
      });
      req.logger.info(
        {
          action: 'admin.rolesMgmt.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          roleId: params.id,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.rolesMgmt.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(remap(err));
    }
  },

  async delete(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.rolesMgmt.delete',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const params = req.params as unknown as RoleIdParamInferred;
      const result = await svc.deleteRole(req.user!.id, params.id);
      req.logger.info(
        {
          action: 'admin.rolesMgmt.delete',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          roleId: params.id,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.rolesMgmt.delete',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(remap(err));
    }
  },

  async grant(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.rolesMgmt.grant',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const params = req.params as unknown as RolePermissionParamsInferred;
      const result = await svc.grantRolePermission(
        req.user!.id,
        params.id,
        params.permId,
      );
      req.logger.info(
        {
          action: 'admin.rolesMgmt.grant',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          roleId: params.id,
          permissionId: params.permId,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.rolesMgmt.grant',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      // D-CRC-6 (fixed in translatePgError P0002 two-token handler): the
      // fn_role_permission_grant P0002 'permission_not_found' tag now surfaces
      // unchanged as NotFoundError('permission_not_found') via client.ts.
      next(remap(err));
    }
  },

  async revoke(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.rolesMgmt.revoke',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const params = req.params as unknown as RolePermissionParamsInferred;
      const result = await svc.revokeRolePermission(
        req.user!.id,
        params.id,
        params.permId,
      );
      req.logger.info(
        {
          action: 'admin.rolesMgmt.revoke',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          roleId: params.id,
          permissionId: params.permId,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.rolesMgmt.revoke',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(remap(err));
    }
  },
};
