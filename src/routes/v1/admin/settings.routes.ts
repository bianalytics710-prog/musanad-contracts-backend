/**
 * /api/v1/admin/settings — system_setting CRUD (R-PA4).
 *
 *   GET  /          — auth + settings.read   → fn_system_setting_list
 *   PUT  /:key      — auth + settings.write  → fn_system_setting_set
 */
import { Router } from 'express';
import { z } from 'zod';
import { adminSettingsController } from '../../../controllers/admin-settings.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';

const router = Router();

router.use(authenticate);

router.get(
  '/',
  authedReadRateLimiter,
  authorise(['settings.read']),
  adminSettingsController.list,
);

const keyParamSchema = z.object({
  key: z
    .string()
    .trim()
    .min(1)
    .max(80)
    .regex(/^[a-zA-Z][a-zA-Z0-9]*$/u, 'key must be camelCase identifier'),
});

const setBodySchema = z
  .object({
    value: z.unknown(),
  })
  .strict()
  .refine((v) => v.value !== undefined, {
    message: 'value is required',
  });

router.put(
  '/:key',
  authedWriteRateLimiter,
  authorise(['settings.write']),
  validate(keyParamSchema, 'params'),
  validate(setBodySchema, 'body'),
  adminSettingsController.set,
);

export default router;
