/**
 * /api/v1/signature-invitations routes — M3 (S8).
 *
 * Single endpoint:
 *   POST /api/v1/signature-invitations/:id/cancel — fn_signature_invitation_cancel
 *
 * Auth: JWT required. Permission: signature.cancel (NOT signature.send —
 * drafter cannot self-cancel; AC-S8-03). The fn_ enforces this server-side
 * via fn_current_user_has_permission.
 */
import { Router } from 'express';
import { signatureController } from '../../controllers/signature.controller';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import {
  CancelInvitationDtoSchema,
  SignatureInvitationIdParamSchema,
} from '../../schemas/signature.schemas';

const router = Router();

router.use(authenticate);

// POST /api/v1/signature-invitations/:id/cancel — S8
router.post(
  '/:id/cancel',
  authedWriteRateLimiter,
  authorise(['signature.cancel']),
  validate(SignatureInvitationIdParamSchema, 'params'),
  validate(CancelInvitationDtoSchema, 'body'),
  signatureController.cancelInvitation,
);

export default router;
