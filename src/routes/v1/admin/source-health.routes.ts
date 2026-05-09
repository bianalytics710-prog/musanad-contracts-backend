/**
 * M7 — /api/v1/admin/source-health (CR-A).
 *
 *   GET / → adminSourceHealthController.list (fn_source_health_list)
 *
 * Permission: source.read (gated inside fn_).
 */
import { Router } from 'express';
import { authenticate } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { authedReadRateLimiter } from '../../../middleware/rate-limit.middleware';
import { adminSourceHealthController } from '../../../controllers/admin/source-health.controller';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

router.get('/', authedReadRateLimiter, adminSourceHealthController.list);

export default router;
