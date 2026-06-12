/**
 * /api/v1/admin/ai-actions — platform admin catalog viewer + tenant toggle.
 *
 * GET    /api/v1/admin/ai-actions          — list catalog with tenant override
 * PATCH  /api/v1/admin/ai-actions/:code    — toggle is_enabled for current tenant
 *
 * Gated by existing system.config.manage permission.
 */
import type { NextFunction, Request, Response } from 'express';
import { z } from 'zod';
import { db } from '../../database/client';

const toggleBodySchema = z.object({
  isEnabled: z.boolean(),
});

const codeParamSchema = z.object({
  code: z
    .string()
    .min(2)
    .max(80)
    .regex(/^[a-z][a-z0-9_]*$/),
});

export const aiActionsAdminController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const userId = req.user!.id;
    try {
      const result = await db.callFunction<{ data?: unknown[] }>(
        'fn_action_registry_for_tenant',
        [userId],
        { actorId: userId, tenantId: req.tenantId },
      );
      res.json(result ?? { data: [] });
    } catch (err) {
      next(err);
    }
  },

  async toggle(req: Request, res: Response, next: NextFunction): Promise<void> {
    const userId = req.user!.id;
    try {
      const { code } = codeParamSchema.parse(req.params);
      const { isEnabled } = toggleBodySchema.parse(req.body);
      const result = await db.callFunction(
        'fn_action_set_enabled',
        [code, isEnabled, userId],
        { actorId: userId, tenantId: req.tenantId },
      );
      res.json(result);
    } catch (err) {
      next(err);
    }
  },
};
