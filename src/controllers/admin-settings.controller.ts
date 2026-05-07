/**
 * Admin settings controller (R-PA4).
 *
 *   GET /api/v1/admin/settings        → fn_system_setting_list
 *   PUT /api/v1/admin/settings/:key   → fn_system_setting_set(key, value, actor)
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';

interface SystemSettingRow {
  key: string;
  value: unknown;
  description: string | null;
  category: 'general' | 'uae_pass' | 'branding';
  isSecret: boolean;
  updatedAt: string;
}

interface SystemSettingListResponse {
  settings: SystemSettingRow[];
}

interface SystemSettingSetResponse {
  key: string;
  value: unknown;
  category: 'general' | 'uae_pass' | 'branding';
  updatedAt: string;
}

export const adminSettingsController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.settings.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const result = await db.callFunction<SystemSettingListResponse>(
        'fn_system_setting_list',
        [],
        { actorId: req.user!.id },
      );

      req.logger.info(
        {
          action: 'admin.settings.list',
          userId: req.user?.id,
          count: result?.settings?.length ?? 0,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'admin.settings.list',
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

  async set(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.settings.set', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const { key } = req.params as unknown as { key: string };
      const { value } = req.body as { value: unknown };

      const result = await db.callFunction<SystemSettingSetResponse>(
        'fn_system_setting_set',
        [key, JSON.stringify(value), req.user!.id],
        { actorId: req.user!.id },
      );

      req.logger.info(
        {
          action: 'admin.settings.set',
          userId: req.user?.id,
          settingKey: key,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'admin.settings.set',
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
