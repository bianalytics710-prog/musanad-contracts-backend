/**
 * M16 / CR-H — /api/v1/advisory-drafts routes.
 *
 * 7 HTTP endpoints + 1 dispatch-log sub-route:
 *   POST   /advisory-drafts/generate          — generate (LLM + persist)
 *   GET    /advisory-drafts                   — list
 *   GET    /advisory-drafts/:id               — get by id
 *   POST   /advisory-drafts/:id/approve       — approve
 *   POST   /advisory-drafts/:id/reject        — reject
 *   POST   /advisory-drafts/:id/modify        — modify text
 *   POST   /advisory-drafts/:id/dispatch      — dispatch (SMTP + capture)
 *   GET    /advisory-drafts/:id/dispatch-log  — advisory dispatch log
 *
 * Permissions:
 *   generate/list/getById/approve/reject/modify: advisory.draft.review
 *   dispatch: advisory.dispatch
 *   dispatch-log: advisory.draft.review OR notification.dispatch_log.read (authoriseAnyOf)
 */
import { Router } from 'express';
import { authenticate, authorise, authoriseAnyOf } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { validate } from '../../middleware/validation.middleware';
import { advisoryDraftsController } from '../../controllers/advisory-drafts.controller';
import {
  generateAdvisoryDraftSchema,
  approveAdvisoryDraftSchema,
  rejectAdvisoryDraftSchema,
  modifyAdvisoryDraftSchema,
  dispatchAdvisoryDraftSchema,
} from '../../schemas/advisory-drafts.schemas';

const router = Router();

const DRAFT_REVIEW_PERMISSION = ['advisory.draft.review'] as const;
const DISPATCH_PERMISSION = ['advisory.dispatch'] as const;
const DISPATCH_LOG_PERMISSIONS = ['advisory.draft.review', 'notification.dispatch_log.read'] as const;

// POST /advisory-drafts/generate
// Must be mounted BEFORE /:id to avoid capturing 'generate' as the id param.
router.post(
  '/generate',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  validate(generateAdvisoryDraftSchema, 'body'),
  advisoryDraftsController.generate,
);

// 2026-06-14 — must be mounted BEFORE /:id for the same reason as /generate.
// Express matches in declaration order; /:id would otherwise capture
// 'from-risk-case', 'by-contract', 'recipient' as the id param.
router.post(
  '/from-risk-case',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  advisoryDraftsController.generateFromRiskCase,
);

router.get(
  '/by-contract/:contractId',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  advisoryDraftsController.listForContract,
);

// 2026-06-15 — Phase 2: drafts awaiting executive review.
router.get(
  '/pending-for-executive',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  advisoryDraftsController.pendingForExecutive,
);

router.get(
  '/recipient/:contractId',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  advisoryDraftsController.resolveRecipient,
);

// GET /advisory-drafts — list (query params parsed inside controller)
router.get(
  '/',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  advisoryDraftsController.list,
);

// GET /advisory-drafts/:id
router.get(
  '/:id',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  advisoryDraftsController.getById,
);

// POST /advisory-drafts/:id/approve
router.post(
  '/:id/approve',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  validate(approveAdvisoryDraftSchema, 'body'),
  advisoryDraftsController.approve,
);

// POST /advisory-drafts/:id/reject
router.post(
  '/:id/reject',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  validate(rejectAdvisoryDraftSchema, 'body'),
  advisoryDraftsController.reject,
);

// POST /advisory-drafts/:id/modify
router.post(
  '/:id/modify',
  authenticate,
  rlsMiddleware,
  authorise(DRAFT_REVIEW_PERMISSION),
  validate(modifyAdvisoryDraftSchema, 'body'),
  advisoryDraftsController.modify,
);

// POST /advisory-drafts/:id/dispatch
router.post(
  '/:id/dispatch',
  authenticate,
  rlsMiddleware,
  authorise(DISPATCH_PERMISSION),
  validate(dispatchAdvisoryDraftSchema, 'body'),
  advisoryDraftsController.dispatch,
);

// GET /advisory-drafts/:id/dispatch-log
router.get(
  '/:id/dispatch-log',
  authenticate,
  rlsMiddleware,
  authoriseAnyOf(DISPATCH_LOG_PERMISSIONS),
  advisoryDraftsController.dispatchLog,
);

// ─── 2026-06-14 — Risk-case workflow /:id/* sub-routes (after /:id) ─────
router.post(
  '/:id/send-directly',
  authenticate, rlsMiddleware, authorise(DISPATCH_PERMISSION),
  advisoryDraftsController.sendDirectly,
);
router.post(
  '/:id/route-for-review',
  authenticate, rlsMiddleware, authorise(DRAFT_REVIEW_PERMISSION),
  advisoryDraftsController.routeForReview,
);
router.post(
  '/:id/exec-approve',
  authenticate, rlsMiddleware, authorise(DRAFT_REVIEW_PERMISSION),
  advisoryDraftsController.execApprove,
);
router.post(
  '/:id/exec-modify',
  authenticate, rlsMiddleware, authorise(DRAFT_REVIEW_PERMISSION),
  advisoryDraftsController.execModify,
);
router.post(
  '/:id/send-after-review',
  authenticate, rlsMiddleware, authorise(DISPATCH_PERMISSION),
  advisoryDraftsController.sendAfterReview,
);
router.post(
  '/:id/resend',
  authenticate, rlsMiddleware, authorise(DISPATCH_PERMISSION),
  advisoryDraftsController.resend,
);

export default router;
