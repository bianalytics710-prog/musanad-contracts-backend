/**
 * Dev login personas visibility controller.
 *
 * Backs the platform-admin toggle UI for the one-click login panel. The
 * GET endpoint is intentionally pre-auth — the login page itself calls it
 * before the user has signed in. Everything in there is dev-only metadata
 * (which persona keys to hide); no sensitive data.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

export const devLoginPersonasController = {
  /**
   * GET /api/v1/public/dev-login-personas — public, no auth required.
   * Returns the current "hidden" array. Empty = all visible.
   */
  get: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_dev_login_personas_get', method: req.method, path: req.path });
    try {
      const result = await db.callFunction<string[]>(
        'fn_dev_login_personas_get',
        [],
        { tenantId: ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_dev_login_personas_get', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: { hidden: result ?? [] } });
    } catch (error) {
      req.logger.error({ action: 'fn_dev_login_personas_get', duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  /**
   * PUT /api/v1/admin/dev-login-personas — admin only, requires
   * dev.login_personas.manage. Body: { hidden: string[] }.
   */
  set: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_dev_login_personas_set', method: req.method, path: req.path, userId: req.user?.id });
    try {
      const body = req.body as { hidden?: unknown };
      const hidden = Array.isArray(body.hidden) ? body.hidden.filter((v) => typeof v === 'string') : [];
      // db.callFunction's auto-stringify only fires on arrays containing
      // objects. Wrap as JSON string so pg binds it as JSONB, not text[].
      const result = await db.callFunction<{ hidden: string[]; updatedBy: number }>(
        'fn_dev_login_personas_set',
        [JSON.stringify(hidden), req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_dev_login_personas_set', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200, hiddenCount: hidden.length });
      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_dev_login_personas_set', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },
};
