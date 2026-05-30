/**
 * CR-V — Admin Modules Controller.
 *
 * 5 endpoints for product module + role × module matrix management:
 *
 *   GET    /api/v1/admin/modules               → fn_product_module_list()
 *   PATCH  /api/v1/admin/modules/:key          → fn_product_module_set(key, isEnabled, reason)
 *   PATCH  /api/v1/admin/bundles/:code         → fn_product_bundle_set(code, isEnabled, reason)
 *   GET    /api/v1/admin/role-modules          → fn_role_module_matrix_get()
 *   PATCH  /api/v1/admin/role-modules/:roleId/:moduleKey → fn_role_module_access_set(roleId, moduleKey, isAllowed, reason)
 *
 * All require authenticate + authorise(['settings.write']).
 * Error mapping: 42501 → 403, 22023 → 400 (invalid module key / bundle code /
 * isEnabled type), P0002 → 404. Default → 500 via global error middleware.
 *
 * Response shape per project convention:
 *   { success: true, data: <fn_ JSONB output> }
 *
 * Audit: all writes pass through fn_'s that emit INSERT INTO audit_log internally
 * (per migration 343 design). No explicit audit call needed here.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../../database/client';
import { ValidationError } from '../../utils/errors.util';
import type {
  PatchModuleBodyInferred,
  PatchBundleBodyInferred,
  PatchRoleModuleBodyInferred,
} from '../../schemas/modules.schemas';
import { ADNOC_TENANT_ID } from '../../types/risk-score.types';

// ─── fn_ result shapes ────────────────────────────────────────────────────────

interface ProductModuleListResult {
  bundles?: unknown[];
  modules?: unknown[];
  [key: string]: unknown;
}

interface ProductModuleSetResult {
  key: string;
  isEnabled: boolean;
  reason: string | null;
  childrenAffected?: number;
  [key: string]: unknown;
}

interface ProductBundleSetResult {
  code: string;
  isEnabled: boolean;
  reason: string | null;
  modulesAffected?: number;
  [key: string]: unknown;
}

interface RoleModuleMatrixResult {
  roles?: unknown[];
  modules?: unknown[];
  matrix?: unknown;
  [key: string]: unknown;
}

interface RoleModuleAccessSetResult {
  roleId: number;
  moduleKey: string;
  isAllowed: boolean | null;
  reason: string | null;
  [key: string]: unknown;
}

// ─── Controller ──────────────────────────────────────────────────────────────

export const adminModulesController = {

  // ============================================================
  // GET /api/v1/admin/modules
  // Returns the full product module catalog with effective enable state
  // per current tenant. Drives the Admin Product Modules screen (CR-X).
  // ============================================================
  listModules: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'admin.modules.list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    }, 'Controller entry');

    try {
      // fn_product_module_list() takes NO args — reads actor from GUC (migration 344)
      const result = await db.callFunction<ProductModuleListResult>(
        'fn_product_module_list',
        [],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'admin.modules.list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      }, 'Controller exit');

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'admin.modules.list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      }, 'Controller error');
      next(error);
    }
  },

  // ============================================================
  // PATCH /api/v1/admin/modules/:key
  // Toggle a single module on/off. Parent disable cascades to children.
  // ============================================================
  patchModule: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const moduleKey = req.params['key'] ?? '';
    req.logger.info({
      action: 'admin.modules.patch',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
      moduleKey,
    }, 'Controller entry');

    try {
      if (!moduleKey) {
        throw new ValidationError('moduleKey path parameter is required', { key: 'required' });
      }

      const body = req.body as PatchModuleBodyInferred;

      // fn_product_module_set(key, is_enabled, reason) — 3 args, reads actor from GUC
      const result = await db.callFunction<ProductModuleSetResult>(
        'fn_product_module_set',
        [moduleKey, body.isEnabled, body.reason ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'admin.modules.patch',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
        moduleKey,
        isEnabled: body.isEnabled,
        childrenAffected: result?.childrenAffected,
      }, 'Controller exit');

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'admin.modules.patch',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
        moduleKey,
      }, 'Controller error');
      next(error);
    }
  },

  // ============================================================
  // PATCH /api/v1/admin/bundles/:code
  // Toggle a bundle on/off. Bundle disable cascades to all child modules.
  // ============================================================
  patchBundle: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const bundleCode = req.params['code'] ?? '';
    req.logger.info({
      action: 'admin.bundles.patch',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
      bundleCode,
    }, 'Controller entry');

    try {
      if (!bundleCode) {
        throw new ValidationError('bundleCode path parameter is required', { code: 'required' });
      }

      const body = req.body as PatchBundleBodyInferred;

      // fn_product_bundle_set(code, is_enabled, reason) — 3 args, reads actor from GUC
      const result = await db.callFunction<ProductBundleSetResult>(
        'fn_product_bundle_set',
        [bundleCode, body.isEnabled, body.reason ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'admin.bundles.patch',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
        bundleCode,
        isEnabled: body.isEnabled,
        modulesAffected: result?.modulesAffected,
      }, 'Controller exit');

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'admin.bundles.patch',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
        bundleCode,
      }, 'Controller error');
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/admin/role-modules
  // Full role × enabled-module matrix with tri-state cells.
  // Drives the Admin Role-Module Matrix screen (CR-X).
  // ============================================================
  getRoleModuleMatrix: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'admin.role-modules.get',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    }, 'Controller entry');

    try {
      // fn_role_module_matrix_get() takes NO args — reads actor from GUC (migration 344)
      const result = await db.callFunction<RoleModuleMatrixResult>(
        'fn_role_module_matrix_get',
        [],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'admin.role-modules.get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      }, 'Controller exit');

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'admin.role-modules.get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      }, 'Controller error');
      next(error);
    }
  },

  // ============================================================
  // PATCH /api/v1/admin/role-modules/:roleId/:moduleKey
  // Toggle role × module access cell (allow=true | deny=false | clear=null).
  // ============================================================
  patchRoleModuleAccess: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const roleIdRaw = req.params['roleId'] ?? '';
    const moduleKey = req.params['moduleKey'] ?? '';
    req.logger.info({
      action: 'admin.role-modules.patch',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
      roleId: roleIdRaw,
      moduleKey,
    }, 'Controller entry');

    try {
      const roleId = parseInt(roleIdRaw, 10);
      if (!Number.isFinite(roleId) || roleId <= 0) {
        throw new ValidationError('roleId must be a positive integer', { roleId: 'invalid' });
      }
      if (!moduleKey) {
        throw new ValidationError('moduleKey path parameter is required', { moduleKey: 'required' });
      }

      const body = req.body as PatchRoleModuleBodyInferred;
      // isAllowed: true = allow, false = deny, null = clear override (use module default)
      const isAllowed: boolean | null = body.isAllowed ?? null;

      // fn_role_module_access_set(role_id, module_key, is_allowed, reason) — 4 args, reads actor from GUC
      const result = await db.callFunction<RoleModuleAccessSetResult>(
        'fn_role_module_access_set',
        [roleId, moduleKey, isAllowed, body.reason ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'admin.role-modules.patch',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
        roleId,
        moduleKey,
        isAllowed,
      }, 'Controller exit');

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'admin.role-modules.patch',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
        moduleKey,
      }, 'Controller error');
      next(error);
    }
  },
};
