/**
 * M20 / CR-L — Admin-only /api/v1/admin/reports routes.
 *
 * Template CRUD:
 *   GET    /admin/reports/templates                — admin list (report.template.manage)
 *   GET    /admin/reports/templates/:id            — detail
 *   POST   /admin/reports/templates                — create
 *   PUT    /admin/reports/templates/:id            — update
 *   DELETE /admin/reports/templates/:id            — soft delete
 *
 * Worker-only (internal, gated by platform_admin / Super Admin role):
 *   GET    /admin/reports/runs/pending             — fn_report_run_pending_get
 *   POST   /admin/reports/runs/:id/complete        — fn_report_run_complete
 *   GET    /admin/reports/data/:slug               — fn_report_data_<slug>
 *
 * Mounted by admin/index.ts as `router.use('/reports', adminReportsRouter)`.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';
import { reportController } from '../../../controllers/report.controller';
import {
  createReportTemplateSchema,
  updateReportTemplateSchema,
  completeReportRunSchema,
  reportDataRequestSchema,
} from '../../../schemas/report.schemas';
import { ForbiddenError } from '../../../utils/errors.util';

const router = Router();

// Internal-only gate: platform_admin / Super Admin only.
const requireInternalActor = (
  req: import('express').Request,
  _res: import('express').Response,
  next: import('express').NextFunction,
): void => {
  if (!req.user) return next(new ForbiddenError('Internal worker endpoint'));
  if (req.user.role !== 'platform_admin' && req.user.role !== 'Super Admin') {
    return next(new ForbiddenError('Internal worker endpoint'));
  }
  next();
};

router.use(authenticate);
router.use(rlsMiddleware);

const MANAGE_PERMISSION = ['report.template.manage'] as const;

// ─── Worker pickup routes (literal — mount before /templates/:id) ────
router.get(
  '/runs/pending',
  authedReadRateLimiter,
  requireInternalActor,
  reportController.pendingRuns,
);

router.post(
  '/runs/:id/complete',
  authedWriteRateLimiter,
  requireInternalActor,
  validate(completeReportRunSchema, 'body'),
  reportController.completeRun,
);

// ─── Data fns — single dispatcher mounted under /data/:slug ──────────
// Note: this is a GET request; api-contracts §designNotes specify the
// worker invokes via direct DB. We expose them as GET with a JSON body
// optional via the dispatcher (Express does not parse GET bodies in
// some clients; the worker can also POST). To be safe, we mount BOTH.
router.get(
  '/data/:slug',
  authedReadRateLimiter,
  requireInternalActor,
  validate(reportDataRequestSchema, 'body'),
  reportController.getReportData,
);
router.post(
  '/data/:slug',
  authedReadRateLimiter,
  requireInternalActor,
  validate(reportDataRequestSchema, 'body'),
  reportController.getReportData,
);

// ─── Template CRUD ───────────────────────────────────────────────────
router.get(
  '/templates',
  authedReadRateLimiter,
  authorise(MANAGE_PERMISSION),
  reportController.listTemplatesAdmin,
);

router.get(
  '/templates/:id',
  authedReadRateLimiter,
  authorise(MANAGE_PERMISSION),
  reportController.getTemplateById,
);

router.post(
  '/templates',
  authedWriteRateLimiter,
  authorise(MANAGE_PERMISSION),
  validate(createReportTemplateSchema, 'body'),
  reportController.createTemplate,
);

router.put(
  '/templates/:id',
  authedWriteRateLimiter,
  authorise(MANAGE_PERMISSION),
  validate(updateReportTemplateSchema, 'body'),
  reportController.updateTemplate,
);

router.delete(
  '/templates/:id',
  authedWriteRateLimiter,
  authorise(MANAGE_PERMISSION),
  reportController.deleteTemplate,
);

export default router;
