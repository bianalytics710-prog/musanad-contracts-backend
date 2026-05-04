/**
 * /api/v1/sign/* — PUBLIC token-bearer (verify_jwt=false) namespace.
 *
 * 5 endpoints (S3, S4, S5, S11, S12). Authentication = invitation_token
 * plaintext in URL path; the fn_ hashes-and-matches server-side. POST
 * /qa/message ALSO requires X-Session-Token header.
 *
 * Route ordering (W1 — most-specific FIRST so Express does not bind a
 * literal path component as :invitationToken on the bare GET):
 *   1. POST /:invitationToken/qa/message    — S12 (SSE; deepest path)
 *   2. POST /:invitationToken/qa/session    — S11
 *   3. POST /:invitationToken/sign          — S4
 *   4. POST /:invitationToken/decline       — S5
 *   5. GET  /:invitationToken               — S3 (LAST — bare token shape)
 *
 * Note: this router does NOT use authenticate. It relies on:
 *   - publicSignerRateLimiter (per-IP)
 *   - InvitationTokenParamSchema (token shape validation)
 *   - the fn_ DEFINER token hash match (true authentication)
 */
import { Router } from 'express';
import { signPublicController } from '../../controllers/sign-public.controller';
import { signerQaController } from '../../controllers/signer-qa.controller';
import { validate } from '../../middleware/validation.middleware';
import { publicSignerRateLimiter } from '../../middleware/rate-limit.middleware';
import {
  DeclineContractDtoSchema,
  InvitationTokenParamSchema,
  SignContractDtoSchema,
  SignerQaRecordMessageDtoSchema,
  SignerQaSessionStartDtoSchema,
} from '../../schemas/signature.schemas';

const router = Router();

// ============================================================
// W1 — most-specific routes FIRST. The bare GET /:invitationToken
// must remain LAST so /:invitationToken/sign etc. resolve correctly.
// ============================================================

// S12 — POST /api/v1/sign/:invitationToken/qa/message — SSE
router.post(
  '/:invitationToken/qa/message',
  publicSignerRateLimiter,
  validate(InvitationTokenParamSchema, 'params'),
  validate(SignerQaRecordMessageDtoSchema, 'body'),
  signerQaController.recordMessage,
);

// S11 — POST /api/v1/sign/:invitationToken/qa/session
router.post(
  '/:invitationToken/qa/session',
  publicSignerRateLimiter,
  validate(InvitationTokenParamSchema, 'params'),
  validate(SignerQaSessionStartDtoSchema, 'body'),
  signerQaController.sessionStart,
);

// S4 — POST /api/v1/sign/:invitationToken/sign
router.post(
  '/:invitationToken/sign',
  publicSignerRateLimiter,
  validate(InvitationTokenParamSchema, 'params'),
  validate(SignContractDtoSchema, 'body'),
  signPublicController.sign,
);

// S5 — POST /api/v1/sign/:invitationToken/decline
router.post(
  '/:invitationToken/decline',
  publicSignerRateLimiter,
  validate(InvitationTokenParamSchema, 'params'),
  validate(DeclineContractDtoSchema, 'body'),
  signPublicController.decline,
);

// S3 — GET /api/v1/sign/:invitationToken — bare; MUST be LAST.
router.get(
  '/:invitationToken',
  publicSignerRateLimiter,
  validate(InvitationTokenParamSchema, 'params'),
  signPublicController.getByInvitationToken,
);

export default router;
