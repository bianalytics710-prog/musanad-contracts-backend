/**
 * M16 / CR-H — Notification Dispatch Log controller.
 *
 * 2 endpoints: list (paginated) + get-by-id (full row).
 * Platform Admin only (notification.dispatch_log.read).
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import { listNotificationDispatchLogSchema } from '../schemas/notification-dispatch-log.schemas';

export const notificationDispatchLogController = {

  list: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_notification_dispatch_log_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = listNotificationDispatchLogSchema.parse(req.query);
      const result = await db.callFunction('fn_notification_dispatch_log_list', [
        req.user!.id,
        params.channel ?? null,
        params.status ?? null,
        params.notificationKind ?? null,
        params.priority ?? null,
        params.recipientUserId ?? null,
        params.from ?? null,
        params.to ?? null,
        params.page,
        params.limit,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_notification_dispatch_log_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_notification_dispatch_log_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  getById: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_notification_dispatch_log_get_by_id',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction('fn_notification_dispatch_log_get_by_id', [
        req.user!.id,
        id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'dispatch_log_not_found', 'Notification dispatch log entry not found');

      req.logger.info({
        action: 'fn_notification_dispatch_log_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_notification_dispatch_log_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },
};
