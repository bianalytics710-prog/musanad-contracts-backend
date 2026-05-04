/**
 * /api/v1/signature-parties routes — M3 (S7).
 *
 * Single endpoint:
 *   POST /api/v1/signature-parties/:id/resend  — fn_signature_invitation_resend
 *
 * Auth: JWT required (verify_jwt=true). Permission: signature.send.
 *
 * Note: The S1 endpoint (POST /contracts/:id/signature-parties) is mounted
 * on contracts.routes.ts because it is :id-prefixed under contracts. This
 * file owns the namespace endpoints that key off signature_party.id.
 */
import { Router } from 'express';
import { signatureController } from '../../controllers/signature.controller';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import {
  ResendInvitationDtoSchema,
  SignaturePartyIdParamSchema,
} from '../../schemas/signature.schemas';

const router = Router();

router.use(authenticate);

// POST /api/v1/signature-parties/:id/resend — S7
router.post(
  '/:id/resend',
  authedWriteRateLimiter,
  authorise(['signature.send']),
  validate(SignaturePartyIdParamSchema, 'params'),
  validate(ResendInvitationDtoSchema, 'body'),
  signatureController.resendInvitation,
);

export default router;
