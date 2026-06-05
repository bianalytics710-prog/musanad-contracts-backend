/**
 * M19 / CR-K — /api/v1/risk-cases routes.
 *
 * 14 endpoints across 3 paths:
 *   GET    /risk-cases                           — list (multiple roles)
 *   GET    /risk-cases/escalation-check          — INTERNAL (platform_admin worker)
 *   POST   /risk-cases/auto-create-from-correlation — INTERNAL (worker)
 *   POST   /risk-cases                           — create (risk.case.create)
 *   GET    /risk-cases/:id                       — detail (visibility-gated)
 *   POST   /risk-cases/:id/assign                — assign
 *   POST   /risk-cases/:id/comments              — add comment
 *   POST   /risk-cases/:id/evidence              — add evidence metadata
 *   GET    /risk-cases/:id/evidence/:attachmentId — fetch + signed URL
 *   POST   /risk-cases/:id/status-transition     — strict-matrix transitions
 *   POST   /risk-cases/:id/escalate              — risk.case.escalate
 *   POST   /risk-cases/:id/accept-risk           — risk.case.accept_risk
 *   POST   /risk-cases/:id/snooze                — snooze (assignee or above)
 *   POST   /risk-cases/:id/close                 — risk.case.close
 *
 * Permission gates per api-contracts.json:
 *   risk.case.create   — create
 *   risk.case.escalate — escalate
 *   risk.case.accept_risk — accept-risk
 *   risk.case.close    — close
 *   (visibility-driven roles for read/assign/comment/evidence/status/snooze
 *    — the fn body enforces visibility and per-case_type permission.)
 *
 * IMPORTANT: literal paths (`/escalation-check`, `/auto-create-from-correlation`)
 * MUST be mounted BEFORE the `/:id` wildcards so they don't get captured as
 * the :id param.
 */
import { Router } from 'express';
import multer from 'multer';
import {
  authenticate,
  authorise,
  authoriseAnyOf,
} from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import { riskCaseController } from '../../controllers/risk-case.controller';
import {
  createRiskCaseSchema,
  assignRiskCaseSchema,
  addRiskCaseCommentSchema,
  statusTransitionRiskCaseSchema,
  escalateRiskCaseSchema,
  acceptRiskCaseSchema,
  snoozeRiskCaseSchema,
  closeRiskCaseSchema,
  autoCreateRiskCaseSchema,
} from '../../schemas/risk-case.schemas';
import { ForbiddenError } from '../../utils/errors.util';

/**
 * DEFECT-CRKL-INTV-1 — Evidence upload is multipart/form-data, not JSON.
 *
 * Mirrors `uploadMulter` in contracts.routes.ts:371-374 and `icvMulter` in
 * compliance-actions.routes.ts:53-65: memoryStorage + 50MB hard cap.
 * The 50MB cap also matches the API contract `fileBytes.max=52428800`
 * and the AC-SK7-02 server-side enforcement requirement.
 */
const evidenceMulter = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 50 * 1024 * 1024 }, // 50 MB
});

const router = Router();

// Internal-only gate: platform_admin or Super Admin role required.
// Worker endpoints use this in lieu of a permission code (they are not
// caller-visible permissions; the fn body is DEFINER + GRANT-restricted).
const requireInternalActor = (req: import('express').Request, _res: import('express').Response, next: import('express').NextFunction): void => {
  if (!req.user) return next(new ForbiddenError('Internal worker endpoint'));
  if (req.user.role !== 'platform_admin' && req.user.role !== 'Super Admin') {
    return next(new ForbiddenError('Internal worker endpoint'));
  }
  next();
};

router.use(authenticate);
router.use(rlsMiddleware);

// ─── INTERNAL (literal paths — mount before /:id) ────────────────────
router.get(
  '/escalation-check',
  authedReadRateLimiter,
  requireInternalActor,
  riskCaseController.escalationCheck,
);

router.post(
  '/auto-create-from-correlation',
  authedWriteRateLimiter,
  requireInternalActor,
  validate(autoCreateRiskCaseSchema, 'body'),
  riskCaseController.autoCreateFromCorrelation,
);

// ─── List / create ───────────────────────────────────────────────────
router.get(
  '/',
  authedReadRateLimiter,
  riskCaseController.list,
);

// Phase A — GET /risk-cases/assignable-users
// Returns active users in risk-eligible roles for the inline reassignment
// dropdown + the new "Assigned to" filter. Mounted BEFORE /:id so the
// literal path doesn't get captured as the id parameter.
router.get(
  '/assignable-users',
  authedReadRateLimiter,
  riskCaseController.assignableUsers,
);

// Phase C — Risk Review bulk action. Literal path BEFORE /:id wildcards
// so it doesn't get captured. Per-case promote / dismiss-as-noise are
// /:id/promote and /:id/dismiss-as-noise — wildcards match below.
import { riskReviewController } from '../../controllers/risk-review.controller';
router.post(
  '/risk-review/bulk',
  authedWriteRateLimiter,
  authorise(['risk.review.manage']),
  riskReviewController.bulk,
);

router.post(
  '/',
  authedWriteRateLimiter,
  authorise(['risk.case.create']),
  validate(createRiskCaseSchema, 'body'),
  riskCaseController.create,
);

// ─── Detail ──────────────────────────────────────────────────────────
router.get(
  '/:id',
  authedReadRateLimiter,
  riskCaseController.getById,
);

// ─── Lifecycle write actions ─────────────────────────────────────────
router.post(
  '/:id/assign',
  authedWriteRateLimiter,
  authoriseAnyOf(['risk.case.create', 'risk.case.escalate']),
  validate(assignRiskCaseSchema, 'body'),
  riskCaseController.assign,
);

router.post(
  '/:id/comments',
  authedWriteRateLimiter,
  validate(addRiskCaseCommentSchema, 'body'),
  riskCaseController.addComment,
);

// DEFECT-CRKL-INTV-1 — multipart/form-data, NOT application/json.
// multer.single('file') MUST run BEFORE the controller — it parses the
// binary body into req.file + populates req.body with the text fields.
// The Zod wire-shape validation (addRiskCaseEvidenceMultipartFieldsSchema)
// is done inside the controller AFTER multer; fileUri is server-derived
// from the Supabase Storage upload and never accepted on the wire.
router.post(
  '/:id/evidence',
  authedWriteRateLimiter,
  authoriseAnyOf(['risk.case.create', 'risk.case.escalate']),
  evidenceMulter.single('file'),
  riskCaseController.addEvidence,
);

router.get(
  '/:id/evidence/:attachmentId',
  authedReadRateLimiter,
  riskCaseController.evidenceGet,
);

router.post(
  '/:id/status-transition',
  authedWriteRateLimiter,
  validate(statusTransitionRiskCaseSchema, 'body'),
  riskCaseController.statusTransition,
);

router.post(
  '/:id/escalate',
  authedWriteRateLimiter,
  authorise(['risk.case.escalate']),
  validate(escalateRiskCaseSchema, 'body'),
  riskCaseController.escalate,
);

router.post(
  '/:id/accept-risk',
  authedWriteRateLimiter,
  authorise(['risk.case.accept_risk']),
  validate(acceptRiskCaseSchema, 'body'),
  riskCaseController.acceptRisk,
);

router.post(
  '/:id/snooze',
  authedWriteRateLimiter,
  validate(snoozeRiskCaseSchema, 'body'),
  riskCaseController.snooze,
);

// P33 — Pari Polish: wake from snooze (no body)
router.post(
  '/:id/unsnooze',
  authedWriteRateLimiter,
  riskCaseController.unsnooze,
);

router.post(
  '/:id/close',
  authedWriteRateLimiter,
  authorise(['risk.case.close']),
  validate(closeRiskCaseSchema, 'body'),
  riskCaseController.close,
);

// Phase C — Risk Review per-case actions. Executive (and any role
// holding risk.review.manage) can promote a Tier 2 case to Tier 1
// (which then auto-routes through the matrix), or dismiss it as noise
// (closes with closure_outcome='no_action').
router.post(
  '/:id/promote',
  authedWriteRateLimiter,
  authorise(['risk.review.manage']),
  riskReviewController.promote,
);

router.post(
  '/:id/dismiss-as-noise',
  authedWriteRateLimiter,
  authorise(['risk.review.manage']),
  riskReviewController.dismiss,
);

export default router;
