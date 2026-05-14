/**
 * M16 / CR-H — /api/v1/users/me/notification-preferences routes.
 *
 * 2 endpoints — bound to the current user (me) via JWT.
 *   GET   /users/me/notification-preferences  — full 28-cell grid
 *   PATCH /users/me/notification-preferences  — upsert single cell
 *
 * Permission: notification.preferences.write.self (all authenticated users).
 * user_id is hard-set to actor_id inside fn_ — no cross-user write possible.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { notificationPreferencesController } from '../../../controllers/notification-preferences.controller';
import { setNotificationPreferenceSchema } from '../../../schemas/notification-preferences.schemas';

const router = Router();

const PERMISSION = ['notification.preferences.write.self'] as const;

// GET /api/v1/users/me/notification-preferences
router.get(
  '/me/notification-preferences',
  authenticate,
  rlsMiddleware,
  authorise(PERMISSION),
  notificationPreferencesController.get,
);

// PATCH /api/v1/users/me/notification-preferences
router.patch(
  '/me/notification-preferences',
  authenticate,
  rlsMiddleware,
  authorise(PERMISSION),
  validate(setNotificationPreferenceSchema, 'body'),
  notificationPreferencesController.set,
);

export default router;
