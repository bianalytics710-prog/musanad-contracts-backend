/**
 * M21 — /api/v1/work-orders router.
 *
 * Routes:
 *   GET  /                       — listMine                 (work.read.assigned)
 *   GET  /assignable-drafters    — assignableDrafters       (work.create)
 *   GET  /:id                    — getById                  (work.read.assigned)
 *   POST /from-contract          — createDraftFromContract  (work.create)
 *   POST /:id/complete           — complete                 (work.read.assigned)
 *   POST /:id/cancel             — cancel                   (work.manage OR work.read.assigned for own)
 *
 * Literal paths (/assignable-drafters, /from-contract) MUST mount BEFORE
 * /:id wildcards so they're not captured as the id parameter.
 */
import { Router } from 'express';
import { authenticate, authorise, authoriseAnyOf } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import { workOrderController } from '../../controllers/work-order.controller';
import {
  createDraftRequestSchema,
  cancelWorkOrderSchema,
  extractFromSourceSchema,
  linkTargetSchema,
  nudgeWorkOrderSchema,
  reassignWorkOrderSchema,
  setStageSchema,
} from '../../schemas/work-order.schemas';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

// ─── Literal paths (mount BEFORE /:id) ───────────────────────────────
router.get(
  '/assignable-drafters',
  authedReadRateLimiter,
  authorise(['work.create']),
  workOrderController.assignableDrafters,
);

// M21 mig 638 — Executive "Assigned Work" list (inverse of GET /).
// work.create is the exec/manager perm that mig 618 granted to executive +
// platform_admin + Super Admin — exactly the personas that need this view.
router.get(
  '/assigned-by-me',
  authedReadRateLimiter,
  authorise(['work.create']),
  workOrderController.listAssignedByMe,
);

// M21 mig 639 — OWNER dropdown source for the Assigned Work table.
router.get(
  '/owner-options',
  authedReadRateLimiter,
  authorise(['work.create']),
  workOrderController.ownerOptions,
);

// M21 — sidecar progress endpoint for the My Work table's Stage column.
// Same auth as listMine (work.read.assigned) since it reads only the
// caller's own work orders' approver enrichment.
router.get(
  '/progress',
  authedReadRateLimiter,
  authorise(['work.read.assigned']),
  workOrderController.progress,
);

// M21 2026-06-12 — Requestor dropdown for the manual modal.
router.get(
  '/requestor-options',
  authedReadRateLimiter,
  authorise(['work.read.assigned']),
  workOrderController.requestorOptions,
);

// M21 2026-06-12 — drafter "Add to my queue". Self-assigned manual create
// for tasks that arrived outside the system (email, chat, etc.). Same
// permission as the queue read because the drafter is the assignee — they
// don't need work.create (which is the exec/manager perm for assigning
// drafts to others).
router.post(
  '/manual',
  authedWriteRateLimiter,
  authorise(['work.read.assigned']),
  workOrderController.createManual,
);

// M21 mig 631 — Similar contract lookup for the manual modal.
router.get(
  '/lookup-contract',
  authedReadRateLimiter,
  authorise(['work.read.assigned']),
  workOrderController.lookupContract,
);

router.get(
  '/counterparty-options',
  authedReadRateLimiter,
  // Both exec (work.create) and drafter (work.read.assigned) need this for
  // the party dropdown — exec's request modal + drafter's compose wizard.
  authoriseAnyOf(['work.create', 'work.read.assigned']),
  workOrderController.counterpartyOptions,
);

router.post(
  '/from-contract',
  authedWriteRateLimiter,
  authorise(['work.create']),
  validate(createDraftRequestSchema, 'body'),
  workOrderController.createDraftRequest,
);

router.post(
  '/extract-from-source',
  authedWriteRateLimiter,
  authorise(['work.read.assigned']),
  validate(extractFromSourceSchema, 'body'),
  workOrderController.extractFromSource,
);

// ─── List + detail + lifecycle ───────────────────────────────────────
router.get(
  '/',
  authedReadRateLimiter,
  authorise(['work.read.assigned']),
  workOrderController.listMine,
);

router.get(
  '/:id',
  authedReadRateLimiter,
  authorise(['work.read.assigned']),
  workOrderController.getById,
);

router.post(
  '/:id/complete',
  authedWriteRateLimiter,
  authorise(['work.read.assigned']),
  workOrderController.complete,
);

// M21 mig 631 — drafter-set stage override on My Work table.
router.patch(
  '/:id/stage',
  authedWriteRateLimiter,
  authorise(['work.read.assigned']),
  validate(setStageSchema, 'body'),
  workOrderController.setStage,
);

router.post(
  '/:id/cancel',
  authedWriteRateLimiter,
  // M21 — exec also needs to cancel their own assignments. widen to anyOf so
  // both the drafter (work.read.assigned) and the requestor (work.create) can
  // cancel; the fn body still enforces tenant scope + active rows.
  authoriseAnyOf(['work.read.assigned', 'work.create']),
  validate(cancelWorkOrderSchema, 'body'),
  workOrderController.cancel,
);

// M21 mig 639 — Executive nudge + reassign.
router.post(
  '/:id/nudge',
  authedWriteRateLimiter,
  authorise(['work.create']),
  validate(nudgeWorkOrderSchema, 'body'),
  workOrderController.nudge,
);

router.post(
  '/:id/reassign',
  authedWriteRateLimiter,
  authorise(['work.create']),
  validate(reassignWorkOrderSchema, 'body'),
  workOrderController.reassign,
);

router.post(
  '/:id/link-target',
  authedWriteRateLimiter,
  authorise(['work.read.assigned']),
  validate(linkTargetSchema, 'body'),
  workOrderController.linkTarget,
);

export default router;
