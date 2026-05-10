/**
 * CR-C — /api/v1/admin/notification-templates (S12, S13)
 *
 *   GET    /                       → fn_notification_template_list
 *   GET    /:id                    → fn_notification_template_get_by_id
 *   PATCH  /:id                    → fn_notification_template_update
 *   POST   /render                 → fn_notification_template_render
 *
 * Permission: notification.template.manage. Tenant-scoped — every controller
 * call forwards `req.tenantId` so app.current_tenant_id GUC is set.
 *
 * Route ordering: literal `/render` MUST appear before `/:id` so Express
 * doesn't bind :id='render'.
 */
import { Router } from 'express';
import { adminNotificationTemplatesController } from '../../../controllers/admin/notification-templates.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { tenantContextMiddleware } from '../../../middleware/tenant-context.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  notificationTemplateIdParamSchema,
  notificationTemplateListQuerySchema,
  notificationTemplateRenderBodySchema,
  notificationTemplateUpdateBodySchema,
} from '../../../schemas/admin-notification-templates.schemas';

const router = Router();

router.use(authenticate);
router.use(tenantContextMiddleware);

// Literal /render BEFORE /:id (Express matches in declaration order).
router.post(
  '/render',
  authedReadRateLimiter,
  authorise(['notification.template.manage']),
  validate(notificationTemplateRenderBodySchema, 'body'),
  adminNotificationTemplatesController.render,
);

router.get(
  '/',
  authedReadRateLimiter,
  authorise(['notification.template.manage']),
  validate(notificationTemplateListQuerySchema, 'query'),
  adminNotificationTemplatesController.list,
);

router.get(
  '/:id',
  authedReadRateLimiter,
  authorise(['notification.template.manage']),
  validate(notificationTemplateIdParamSchema, 'params'),
  adminNotificationTemplatesController.getById,
);

router.patch(
  '/:id',
  authedWriteRateLimiter,
  authorise(['notification.template.manage']),
  validate(notificationTemplateIdParamSchema, 'params'),
  validate(notificationTemplateUpdateBodySchema, 'body'),
  adminNotificationTemplatesController.update,
);

export default router;
