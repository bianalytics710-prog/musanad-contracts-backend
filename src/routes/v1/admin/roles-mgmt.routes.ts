/**
 * CR-C — /api/v1/admin/roles (S15) + role-permissions (S16)
 *
 *   POST   /                                           → fn_role_create
 *   PATCH  /:id                                        → fn_role_update
 *   DELETE /:id                                        → fn_role_delete
 *   POST   /:id/permissions/:permId/grant              → fn_role_permission_grant
 *   DELETE /:id/permissions/:permId/revoke             → fn_role_permission_revoke
 *
 * Permission: role.manage at route layer + fn body.
 *
 * Mounted under /api/v1/admin/roles. The existing /api/v1/roles router
 * (role.routes.ts) handles read paths (list / get-by-id / list-permissions);
 * this admin-mounted variant covers the write surface introduced by CR-C.
 */
import { Router } from 'express';
import { adminRolesMgmtController } from '../../../controllers/admin/roles-mgmt.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { authedWriteRateLimiter } from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  createRoleBodySchema,
  roleIdParamSchema,
  rolePermissionParamsSchema,
  updateRoleBodySchema,
} from '../../../schemas/admin-roles-mgmt.schemas';

const router = Router();

router.use(authenticate);

router.post(
  '/',
  authedWriteRateLimiter,
  authorise(['role.manage']),
  validate(createRoleBodySchema, 'body'),
  adminRolesMgmtController.create,
);

router.patch(
  '/:id',
  authedWriteRateLimiter,
  authorise(['role.manage']),
  validate(roleIdParamSchema, 'params'),
  validate(updateRoleBodySchema, 'body'),
  adminRolesMgmtController.update,
);

router.delete(
  '/:id',
  authedWriteRateLimiter,
  authorise(['role.manage']),
  validate(roleIdParamSchema, 'params'),
  adminRolesMgmtController.delete,
);

router.post(
  '/:id/permissions/:permId/grant',
  authedWriteRateLimiter,
  authorise(['role.manage']),
  validate(rolePermissionParamsSchema, 'params'),
  adminRolesMgmtController.grant,
);

router.delete(
  '/:id/permissions/:permId/revoke',
  authedWriteRateLimiter,
  authorise(['role.manage']),
  validate(rolePermissionParamsSchema, 'params'),
  adminRolesMgmtController.revoke,
);

export default router;
