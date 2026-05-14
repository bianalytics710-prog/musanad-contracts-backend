/**
 * M16 / CR-H — /api/v1/admin/notification-dispatch-log routes.
 *
 * 2 endpoints:
 *   GET /notification-dispatch-log      — paginated list with filters
 *   GET /notification-dispatch-log/:id  — full row detail
 *
 * Permission: notification.dispatch_log.read.
 * Roles: Super Admin, platform_admin.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { notificationDispatchLogController } from '../../../controllers/notification-dispatch-log.controller';
import { listNotificationDispatchLogSchema } from '../../../schemas/notification-dispatch-log.schemas';

const router = Router();

const PERMISSION = ['notification.dispatch_log.read'] as const;

// GET /api/v1/admin/notification-dispatch-log
router.get(
  '/',
  authenticate,
  rlsMiddleware,
  authorise(PERMISSION),
  validate(listNotificationDispatchLogSchema, 'query'),
  notificationDispatchLogController.list,
);

// GET /api/v1/admin/notification-dispatch-log/:id
router.get(
  '/:id',
  authenticate,
  rlsMiddleware,
  authorise(PERMISSION),
  notificationDispatchLogController.getById,
);

export default router;
