/**
 * M22 / CR-MIG-DRIVE — /api/v1/admin/migration/purge-all* routes.
 *
 *   POST /preview     migration.purge.all
 *   POST /            migration.purge.all
 *
 * Purge route is the dedicated carve-out — never integrated with CR-J
 * fn_demo_data_purge. Permission gate enforced at both router + fn level.
 */
import { Router } from 'express';
import { migrationController } from '../../../controllers/migration.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { heavyExportRateLimiter } from '../../../middleware/rate-limit.middleware';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

router.post(
  '/preview',
  heavyExportRateLimiter,
  authorise(['migration.purge.all']),
  migrationController.purgePreview,
);

router.post(
  '/',
  heavyExportRateLimiter,
  authorise(['migration.purge.all']),
  migrationController.purgeExecute,
);

export default router;
