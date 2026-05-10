/**
 * CR-C — /api/v1/admin/email-config (S14)
 *
 *   GET   /              → composed SmtpConfig (authPassRefSet boolean only)
 *   PATCH /              → patches email.* keys (compound: email.config.manage AND settings.write)
 *   POST  /test-send     → composes SMTP transport, sends, times round-trip
 *
 * Compound permission gate (per ep_email_config_patch contract):
 *   email.config.manage AND settings.write — route layer enforces email.config.manage,
 *   controller additionally checks settings.write on PATCH + test-send.
 *
 * Rate limits: authedRead on GET, authedWrite on PATCH + test-send.
 */
import { Router } from 'express';
import { adminEmailConfigController } from '../../../controllers/admin/email-config.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  emailConfigPatchBodySchema,
  emailTestSendBodySchema,
} from '../../../schemas/admin-email-config.schemas';

const router = Router();

router.use(authenticate);

router.get(
  '/',
  authedReadRateLimiter,
  authorise(['email.config.manage']),
  adminEmailConfigController.get,
);

router.patch(
  '/',
  authedWriteRateLimiter,
  authorise(['email.config.manage']),
  validate(emailConfigPatchBodySchema, 'body'),
  adminEmailConfigController.patch,
);

router.post(
  '/test-send',
  authedWriteRateLimiter,
  authorise(['email.config.manage']),
  validate(emailTestSendBodySchema, 'body'),
  adminEmailConfigController.testSend,
);

export default router;
