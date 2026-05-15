/**
 * M20 / CR-L — User-facing /api/v1/reports routes.
 *
 * User endpoints:
 *   GET    /reports/templates                 — user mode (report.read)
 *   POST   /reports/templates/:id/run         — manual trigger (report.read)
 *   GET    /reports/runs/:id                  — poll status + signed URL
 *
 * Admin-only template CRUD is mounted under /api/v1/admin/reports/templates
 * via the separate admin sub-router (admin/reports.routes.ts). The two
 * routers are mounted at different prefixes by routes/v1/index.ts +
 * routes/v1/admin/index.ts.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import { exportRateLimiter } from '../../middleware/export-rate-limit.middleware';
import { reportController } from '../../controllers/report.controller';
import { triggerReportRunSchema } from '../../schemas/report.schemas';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

const READ_PERMISSION = ['report.read'] as const;

// GET /reports/templates  — user-mode (admin-mode toggled via ?adminMode=true)
router.get(
  '/templates',
  authedReadRateLimiter,
  authorise(READ_PERMISSION),
  reportController.listTemplates,
);

// POST /reports/templates/:id/run — manual trigger
// Heavier write that queues a Puppeteer/exceljs job — use the export limiter
// on top of the standard write limiter.
router.post(
  '/templates/:id/run',
  exportRateLimiter,
  authedWriteRateLimiter,
  authorise(READ_PERMISSION),
  validate(triggerReportRunSchema, 'body'),
  reportController.triggerRun,
);

// GET /reports/runs/:id — poll status + mint signed URL when complete
router.get(
  '/runs/:id',
  authedReadRateLimiter,
  authorise(READ_PERMISSION),
  reportController.getRunById,
);

export default router;
