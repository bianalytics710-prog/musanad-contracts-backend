/**
 * /api/v1/sign/* PUBLIC controllers — token-bearer (verify_jwt=false).
 *
 * Three routes covered here:
 *   - GET  /api/v1/sign/:invitationToken               → S3 fn_signature_get_by_invitation_token
 *   - POST /api/v1/sign/:invitationToken/sign          → S4 fn_signature_sign
 *   - POST /api/v1/sign/:invitationToken/decline       → S5 fn_signature_decline
 *
 * Sensitive data:
 *   - The invitation token plaintext is in req.params.invitationToken. Pino
 *     redaction patterns redact `req.params.invitationToken` so the token
 *     does NOT appear in egress logs. Controller logs only the prefix
 *     length + redacted marker for traceability.
 *   - signatureData / signatureImageUrl on the S4 request body are
 *     pino-redacted (M3 redact paths). We never include them in any log.
 *
 * 410 vs 404:
 *   The fn_signature_get_by_invitation_token returns NULL when the
 *   invitation is unknown / expired / cancelled. Per AC-S3-04 the controller
 *   maps NULL → 410 with a SINGLE GENERIC message that does NOT distinguish
 *   the failure mode. The fn_signature_sign / fn_signature_decline RAISE
 *   the same 'invitation_invalid_or_expired' which translatePgError maps
 *   to 410 GoneError directly (database/client.ts P0001 handler).
 *
 * Step-2+ orchestration (DB Impl I-4):
 *   When fn_signature_sign returns stepCompleted=true with
 *   contractNewStatus='awaiting_signature_counterparty', the contract has
 *   advanced to the next signature step but no invitations exist yet for
 *   the new step. The DB layer is intentionally not auto-issuing those —
 *   the design defers that to a JWT-authenticated drafter action
 *   (POST /api/v1/contracts/:id/send-for-signature) re-invoked at the new
 *   step. We log the event explicitly so the orchestrator can surface it.
 */
import type { NextFunction, Request, Response } from 'express';
import * as signatureService from '../services/signature.service';
import { GoneError } from '../utils/errors.util';
import type {
  DeclineContractDtoInferred,
  InvitationTokenParamInferred,
  SignContractDtoInferred,
} from '../schemas/signature.schemas';

/** Mask a token plaintext for log traceability. Returns first 4 chars + '…'. */
const tokenMarker = (token: string | undefined): string => {
  if (!token || token.length < 8) return '[REDACTED]';
  return `${token.slice(0, 4)}…(${token.length}c)`;
};

const ipFromReq = (req: Request): string | null => req.ip || req.socket.remoteAddress || null;
const userAgentFromReq = (req: Request): string | null => {
  const ua = req.headers['user-agent'];
  return typeof ua === 'string' ? ua.slice(0, 1024) : null;
};

export const signPublicController = {
  /**
   * S3 — GET /api/v1/sign/:invitationToken → fn_signature_get_by_invitation_token
   *
   * Token-bearer read. fn_ returns NULL on unknown/expired/cancelled — we
   * map to 410 with a single generic message (AC-S3-04 — never distinguish
   * the failure mode).
   */
  async getByInvitationToken(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const { invitationToken } = req.params as unknown as InvitationTokenParamInferred;
    req.logger.info(
      {
        action: 'signPublic.getByInvitationToken',
        method: req.method,
        path: req.path,
        invitationTokenMarker: tokenMarker(invitationToken),
      },
      'Controller entry',
    );
    try {
      const result = await signatureService.getByInvitationToken(invitationToken);
      if (!result) {
        throw new GoneError('Invitation is invalid or expired');
      }
      req.logger.info(
        {
          action: 'signPublic.getByInvitationToken',
          invitationTokenMarker: tokenMarker(invitationToken),
          invitationId: result.invitation.id,
          contractId: result.contract.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.warn(
        {
          action: 'signPublic.getByInvitationToken',
          invitationTokenMarker: tokenMarker(invitationToken),
          duration: Date.now() - startTime,
          errorType: error instanceof Error ? error.name : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * S4 — POST /api/v1/sign/:invitationToken/sign → fn_signature_sign
   *
   * Token-bearer write. Method gating (typed/drawn/uae_pass/ds_otp) is
   * validated client-side by Zod + server-side by fn_. Sensitive
   * signatureData + signatureImageUrl are NOT logged (Pino redaction).
   */
  async sign(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const { invitationToken } = req.params as unknown as InvitationTokenParamInferred;
    req.logger.info(
      {
        action: 'signPublic.sign',
        method: req.method,
        path: req.path,
        invitationTokenMarker: tokenMarker(invitationToken),
      },
      'Controller entry',
    );
    try {
      const body = req.body as SignContractDtoInferred;
      const result = await signatureService.sign({
        invitationTokenPlain: invitationToken,
        signatureMethod: body.signatureMethod,
        signatureData: body.signatureData ?? null,
        signatureImageUrl: body.signatureImageUrl ?? null,
        uaePassVerificationLevel: body.uaePassVerificationLevel ?? null,
        ipAddress: ipFromReq(req),
        userAgent: userAgentFromReq(req),
        metadata: body.metadata ?? null,
      });
      if (!result) {
        throw new GoneError('Invitation is invalid or expired');
      }
      // Step-2+ orchestration log (DB Impl I-4). When the contract
      // transitions to awaiting_signature_counterparty, drafter must
      // call POST /contracts/:id/send-for-signature again at the new step.
      // No DB-side auto-issue.
      if (
        result.stepCompleted &&
        result.contractNewStatus === 'awaiting_signature_counterparty'
      ) {
        req.logger.info(
          {
            action: 'signPublic.sign.next_step_required',
            invitationId: result.invitationId,
            contractNewStatus: result.contractNewStatus,
          },
          'Step completed; next-step invitations require drafter action (DB Impl I-4)',
        );
      }
      req.logger.info(
        {
          action: 'signPublic.sign',
          invitationTokenMarker: tokenMarker(invitationToken),
          invitationId: result.invitationId,
          stepCompleted: result.stepCompleted,
          contractNewStatus: result.contractNewStatus,
          signatureMethod: body.signatureMethod, // method itself is not sensitive
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.warn(
        {
          action: 'signPublic.sign',
          invitationTokenMarker: tokenMarker(invitationToken),
          duration: Date.now() - startTime,
          errorType: error instanceof Error ? error.name : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * S5 — POST /api/v1/sign/:invitationToken/decline → fn_signature_decline
   *
   * Required-signer decline transitions contract.status to 'rejected';
   * non-required (witness) does not transition.
   */
  async decline(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const { invitationToken } = req.params as unknown as InvitationTokenParamInferred;
    req.logger.info(
      {
        action: 'signPublic.decline',
        method: req.method,
        path: req.path,
        invitationTokenMarker: tokenMarker(invitationToken),
      },
      'Controller entry',
    );
    try {
      const body = req.body as DeclineContractDtoInferred;
      const result = await signatureService.decline({
        invitationTokenPlain: invitationToken,
        declineReason: body.declineReason,
        ipAddress: ipFromReq(req),
        userAgent: userAgentFromReq(req),
      });
      if (!result) {
        throw new GoneError('Invitation is invalid or expired');
      }
      req.logger.info(
        {
          action: 'signPublic.decline',
          invitationTokenMarker: tokenMarker(invitationToken),
          invitationId: result.invitationId,
          contractNewStatus: result.contractNewStatus,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.warn(
        {
          action: 'signPublic.decline',
          invitationTokenMarker: tokenMarker(invitationToken),
          duration: Date.now() - startTime,
          errorType: error instanceof Error ? error.name : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },
};
