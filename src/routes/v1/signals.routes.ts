/**
 * M7 — /api/v1/signals (CR-A).
 *
 *   GET / → signalsController.list (fn_osint_signal_list)
 *
 * Permission: signal.read.all (gated inside fn_).
 */
import { Router } from 'express';
import { authenticate } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import { validate } from '../../middleware/validation.middleware';
import { signalsController } from '../../controllers/signals.controller';
import { osintSignalListQuerySchema } from '../../schemas/signals.schemas';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

router.get(
  '/',
  authedReadRateLimiter,
  validate(osintSignalListQuerySchema, 'query'),
  signalsController.list,
);

export default router;
