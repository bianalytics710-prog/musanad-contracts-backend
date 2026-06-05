/**
 * Sidebar role-order controller — mig 539.
 *
 * GET   /api/v1/admin/sidebar-order       (admin.sidebar.manage)
 *   → Returns the full per-role override map { roleName: moduleKey[] }.
 *     Empty {} means no overrides — FE falls back to MODULES displayOrder.
 *
 * PUT   /api/v1/admin/sidebar-order       (admin.sidebar.manage)
 *   Body: { order: { roleName: string[] } }
 *   → Replaces the full map. Empty array for a role removes the override.
 *
 * The sidebar-order read is also wired into the auth path of /me so an
 * authenticated user fetches the live ordering on every page load without
 * needing a separate round-trip — see auth.controller. The admin UI uses
 * this controller's GET endpoint to populate its editor.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

type RoleOrderMap = Record<string, string[]>;

export const sidebarOrderController = {
  /**
   * GET /api/v1/admin/sidebar-order — admin only.
   * Returns the full override map.
   */
  get: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_sidebar_role_order_get', method: req.method, path: req.path, userId: req.user?.id });
    try {
      const result = await db.callFunction<RoleOrderMap>(
        'fn_sidebar_role_order_get',
        [],
        { actorId: req.user?.id ?? 0, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_sidebar_role_order_get', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: { order: result ?? {} } });
    } catch (error) {
      req.logger.error({ action: 'fn_sidebar_role_order_get', duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  /**
   * PUT /api/v1/admin/sidebar-order — admin only, requires admin.sidebar.manage.
   * Body: { order: { roleName: string[] } }. Replaces the full map.
   */
  set: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_sidebar_role_order_set', method: req.method, path: req.path, userId: req.user?.id });
    try {
      const body = req.body as { order?: unknown };
      const raw = (body.order && typeof body.order === 'object' && !Array.isArray(body.order))
        ? body.order as Record<string, unknown>
        : {};
      const cleaned: RoleOrderMap = {};
      for (const [roleName, arr] of Object.entries(raw)) {
        if (Array.isArray(arr)) {
          const onlyStrings = arr.filter((v): v is string => typeof v === 'string');
          cleaned[roleName] = onlyStrings;
        }
      }
      const result = await db.callFunction<{ order: RoleOrderMap; updatedBy: number }>(
        'fn_sidebar_role_order_set',
        [JSON.stringify(cleaned), req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({
        action: 'fn_sidebar_role_order_set',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
        roleCount: Object.keys(cleaned).length,
      });
      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_sidebar_role_order_set', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },
};
