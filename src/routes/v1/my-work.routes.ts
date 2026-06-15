/**
 * Phase A (mig 640) — /api/v1/my-work router.
 *
 * Single endpoint that returns the actor's UNION-ed inbox. Permission is
 * work.read.assigned (already granted to every persona that owns work).
 * The drafter's existing /api/v1/work-orders endpoint stays untouched.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import { myWorkController } from '../../controllers/my-work.controller';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

router.get(
  '/',
  authedReadRateLimiter,
  authorise(['work.read.assigned']),
  myWorkController.list,
);

// mig 684 — personal work-status overlay. Same permission as the list:
// anyone who owns a My Work queue can annotate their own rows.
router.get(
  '/statuses',
  authedReadRateLimiter,
  authorise(['work.read.assigned']),
  myWorkController.listStatuses,
);

router.post(
  '/status',
  authorise(['work.read.assigned']),
  myWorkController.setStatus,
);

export default router;
