/**
 * M16 / CR-H — Notification Preferences controller.
 *
 * 2 endpoints: GET + PATCH /users/me/notification-preferences.
 * user_id is ALWAYS hard-set to req.user.id in the fn_ — no cross-user write.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { setNotificationPreferenceSchema } from '../schemas/notification-preferences.schemas';

export const notificationPreferencesController = {

  get: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_notification_subscription_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const result = await db.callFunction('fn_notification_subscription_list', [
        req.user!.id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_notification_subscription_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_notification_subscription_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  set: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_notification_subscription_set',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const data = setNotificationPreferenceSchema.parse(req.body);
      const result = await db.callFunction('fn_notification_subscription_set', [
        req.user!.id,
        data.notificationKind,
        data.channel,
        data.priorityMin ?? 'high',
        data.enabled ?? true,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_notification_subscription_set',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_notification_subscription_set',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },
};
