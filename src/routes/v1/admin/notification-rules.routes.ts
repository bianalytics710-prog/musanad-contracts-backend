/**
 * Notification-rules admin routes — Platform Admin trigger-rule registry.
 *
 *   GET    /api/v1/admin/notification-rules                   list
 *   POST   /api/v1/admin/notification-rules                   create
 *   GET    /api/v1/admin/notification-rules/event-types       catalogue (literal)
 *   PATCH  /api/v1/admin/notification-rules/:id/enabled       toggle
 *   PUT    /api/v1/admin/notification-rules/:id               update
 *   DELETE /api/v1/admin/notification-rules/:id               soft-delete
 *
 * Route ordering: literal '/event-types' + '/:id/enabled' must come BEFORE
 * the bare '/:id' PUT/DELETE so Express does not capture those segments as
 * the id.
 *
 * Permission: platform.notifications.manage.
 */
import { Router } from 'express';
import { notificationRulesController } from '../../../controllers/admin/notification-rules.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);
router.use(authorise(['platform.notifications.manage']));

router.get('/', authedReadRateLimiter, notificationRulesController.list);
router.post('/', authedWriteRateLimiter, notificationRulesController.upsertV2);

// Literal paths before generic /:id.
router.get(
  '/event-types',
  authedReadRateLimiter,
  notificationRulesController.eventTypes,
);
router.get(
  '/modules',
  authedReadRateLimiter,
  notificationRulesController.modules,
);
router.get(
  '/context-resolvers',
  authedReadRateLimiter,
  notificationRulesController.contextResolvers,
);
router.patch(
  '/:id/enabled',
  authedWriteRateLimiter,
  notificationRulesController.setEnabled,
);

router.get(
  '/:id/detail',
  authedReadRateLimiter,
  notificationRulesController.getDetail,
);
router.put('/:id', authedWriteRateLimiter, notificationRulesController.upsertV2);
router.delete(
  '/:id',
  authedWriteRateLimiter,
  notificationRulesController.deactivate,
);

export default router;
