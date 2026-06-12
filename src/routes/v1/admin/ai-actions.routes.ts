/**
 * /api/v1/admin/ai-actions/* — Platform Admin AI Chat Action catalog.
 *
 *   GET   /                    — list catalog with this tenant's overrides
 *   PATCH /:code               — toggle is_enabled for this tenant
 *
 * Permission: system.config.manage (existing platform_admin grant).
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { authedReadRateLimiter, authedWriteRateLimiter } from '../../../middleware/rate-limit.middleware';
import { aiActionsAdminController } from '../../../controllers/admin/ai-actions.controller';

const router = Router();
router.use(authenticate);
router.use(rlsMiddleware);

router.get('/', authedReadRateLimiter, authorise(['system.config.manage']), aiActionsAdminController.list);
router.patch('/:code', authedWriteRateLimiter, authorise(['system.config.manage']), aiActionsAdminController.toggle);

export default router;
