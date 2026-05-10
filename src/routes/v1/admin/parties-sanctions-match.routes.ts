/**
 * M9 (CR-B) — /api/v1/admin/parties/sanctions-match
 *
 *   POST / → fn_party_sanctions_match
 *
 * Permission: party.graph.manage (controller-narrowed). The fn body itself
 * gates on party.graph.read OR system caller; the admin route narrows to
 * manage to keep the user-facing path admin-only. CR-E rule engine system
 * pool calls a separate DEFINER carve-out (out of M9 scope).
 *
 * Tenant GUC is set via db.callFunction({ tenantId }) using `req.tenantId`
 * resolved by rls.middleware.
 *
 * Per HITL Q-DA4 lock: this fn returns matches only — does NOT update
 * party.sanctions_status.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { authedWriteRateLimiter } from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { adminPartiesSanctionsMatchController } from '../../../controllers/admin/parties-sanctions-match.controller';
import { partySanctionsMatchInputSchema } from '../../../schemas/party-graph.schemas';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

router.post(
  '/',
  authedWriteRateLimiter,
  authorise(['party.graph.manage']),
  validate(partySanctionsMatchInputSchema, 'body'),
  adminPartiesSanctionsMatchController.match,
);

export default router;
