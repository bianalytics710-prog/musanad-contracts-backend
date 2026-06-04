/**
 * Admin Dev Login Personas routes — mig 538.
 *
 *   PUT /api/v1/admin/dev-login-personas — toggle visibility of personas
 *                                          on the one-click login panel.
 *
 * GET lives under /api/v1/public/dev-login-personas (no auth) because the
 * login page must read it pre-authentication.
 */
import { Router } from 'express';
import { devLoginPersonasController } from '../../../controllers/dev-login-personas.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { authedWriteRateLimiter } from '../../../middleware/rate-limit.middleware';

const router = Router();

router.put(
  '/',
  authenticate,
  authorise(['dev.login_personas.manage']),
  authedWriteRateLimiter,
  devLoginPersonasController.set,
);

export default router;
