/**
 * CR-C — /api/v1/admin/demo
 *
 *   POST /purge                            → fn_demo_data_purge
 *   GET  /data-classification-summary      → fn_data_classification_summary
 *
 * Super Admin gate enforced inside fn_demo_data_purge body. Route layer
 * additionally requires `demo.purge` permission to provide a clear 403
 * envelope before reaching the DB.
 *
 * Rate limit: heavyExportRateLimiter on /purge — fn_demo_data_purge wall-
 * clock SLA is < 60s end-to-end across 38 tables. Summary uses standard
 * authedReadRateLimiter.
 */
import { Router } from 'express';
import { adminDemoController } from '../../../controllers/admin/demo.controller';
import { authenticate, authorise, authoriseAnyOf } from '../../../middleware/auth.middleware';
import {
  authedReadRateLimiter,
  heavyExportRateLimiter,
} from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { demoPurgeBodySchema } from '../../../schemas/admin-demo.schemas';

const router = Router();

router.use(authenticate);

router.post(
  '/purge',
  heavyExportRateLimiter,
  authorise(['demo.purge']),
  validate(demoPurgeBodySchema, 'body'),
  adminDemoController.purge,
);

router.get(
  '/data-classification-summary',
  authedReadRateLimiter,
  // Compound permission per ep_data_classification_summary: any of
  // audit.verify / demo.purge satisfies (Super Admin role-check is also
  // enforced inside the fn body).
  authoriseAnyOf(['audit.verify', 'demo.purge']),
  adminDemoController.dataClassificationSummary,
);

export default router;
