/**
 * /api/v1/auth/* routes.
 */
import { Router } from 'express';
import { authController } from '../../controllers/auth.controller';
import { authenticate } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  loginRateLimiter,
  logoutRateLimiter,
  refreshRateLimiter,
} from '../../middleware/rate-limit.middleware';
import {
  loginSchema,
  logoutSchema,
  refreshTokenSchema,
  uaePassCallbackSchema,
  uaePassInitiateSchema,
} from '../../schemas/auth.schemas';

const router = Router();

router.post('/login', loginRateLimiter, validate(loginSchema, 'body'), authController.login);

router.post(
  '/refresh',
  refreshRateLimiter,
  validate(refreshTokenSchema, 'body'),
  authController.refresh,
);

router.post(
  '/logout',
  logoutRateLimiter,
  authenticate,
  validate(logoutSchema, 'body'),
  authController.logout,
);

// UAE Pass — added per decisions.md G3 (NOT in original M0 OpenAPI yet)
router.post(
  '/uae-pass/initiate',
  validate(uaePassInitiateSchema, 'body'),
  authController.uaePassInitiate,
);
router.post(
  '/uae-pass/callback',
  validate(uaePassCallbackSchema, 'body'),
  authController.uaePassCallback,
);

export default router;
