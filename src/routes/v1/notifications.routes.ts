/**
 * Notifications feed routes — minimal read-only surface for the FE bell.
 *
 *   GET /api/v1/notifications/feed?limit=&offset=
 *     Wraps fn_notification_feed_list. Returns the calling user's in-app
 *     notification_dispatch_log rows (sent + captured_only) newest-first.
 *
 * No new permissions — visibility is enforced by recipient_user_id = actor.
 */
import { Router, type Request, type Response, type NextFunction } from 'express';
import { authenticate } from '../../middleware/auth.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import { db } from '../../database/client';
import { logger } from '../../utils/logger.util';

export const notificationsRouter = Router();
notificationsRouter.use(authenticate);

const intOrDefault = (raw: unknown, fallback: number, max = 200): number => {
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return fallback;
  return Math.min(Math.max(0, Math.floor(n)), max);
};

interface FeedRow {
  id: number;
  notificationKind: string;
  priority: string;
  subject: string | null;
  bodyRendered: string | null;
  contextPayload: Record<string, unknown> | null;
  status: string;
  createdAt: string;
  deliveryCompletedAt: string | null;
}

interface FeedResult {
  data: FeedRow[];
  pagination: { total: number; limit: number; offset: number };
}

notificationsRouter.get(
  '/feed',
  authedReadRateLimiter,
  async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const start = Date.now();
    try {
      const limit = intOrDefault(req.query['limit'], 50, 200);
      const offset = intOrDefault(req.query['offset'], 0);
      const result = await db.callFunction<FeedResult>(
        'fn_notification_feed_list',
        [req.user!.id, limit, offset],
        { actorId: req.user!.id },
      );
      logger.info(
        {
          action: 'notifications.feed',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 200,
          count: result?.data?.length ?? 0,
        },
        'Notifications feed delivered',
      );
      res.status(200).json(result);
    } catch (e) {
      logger.error(
        {
          action: 'notifications.feed',
          userId: req.user?.id,
          duration: Date.now() - start,
          errorType: e instanceof Error ? e.name : 'UNKNOWN',
        },
        'Notifications feed failed',
      );
      next(e);
    }
  },
);
