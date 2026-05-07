/**
 * /api/v1/contracts/:id/{signature-parties, send-for-signature, signatures}
 * + /api/v1/signature-parties/:id/resend
 * + /api/v1/signature-invitations/:id/cancel
 *
 * JWT-authenticated controllers for M3 (S1, S2, S6, S7, S8). Each method is
 * a thin HTTP layer: route already validates with Zod, controller forwards
 * to the signature.service single fn_ call, then formats the response.
 *
 * Sensitive data:
 *   - signerEmail / signerPhone in S1 request body — pino-redacted at the
 *     wire layer (logger.util.ts SENSITIVE_PATHS).
 *   - invitationTokenPlaintext in S2 / S7 responses — pino-redacted via
 *     `*.invitationTokenPlaintext` patterns. The mailer (out of M3 scope)
 *     consumes them; we log only counts here.
 *
 * Step-2+ orchestration (DB Impl I-4):
 *   When fn_signature_sign returns stepCompleted=true with
 *   contractNewStatus='awaiting_signature_counterparty', the next-step
 *   invitation issuance is the BE's responsibility. M3 design intentionally
 *   stops at the status transition; the controller for S4 (sign — public
 *   token-bearer) does NOT have JWT-level authority to issue new invitations.
 *   Surfaced as an open issue for the orchestrator — see openIssues in
 *   be-implementation-summary.json. The current code emits a structured log
 *   entry on the transition so the issue is observable in production.
 */
import type { NextFunction, Request, Response } from 'express';
import * as signatureService from '../services/signature.service';
import { ApiError, NotFoundError } from '../utils/errors.util';
import type {
  CancelInvitationDtoInferred,
  ContractIdParamInferred,
  ResendInvitationDtoInferred,
  SignaturePartyCreateBulkDtoInferred,
  SignaturePartyIdParamInferred,
  SignatureInvitationIdParamInferred,
} from '../schemas/signature.schemas';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const signatureController = {
  /** S1 — POST /api/v1/contracts/:id/signature-parties → fn_signature_party_create_bulk */
  async createPartiesBulk(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'signature.createPartiesBulk',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const body = req.body as SignaturePartyCreateBulkDtoInferred;
      const result = await signatureService.createPartiesBulk(
        req.user!.id,
        Number(id),
        body.signers,
      );
      if (!result) {
        throw new NotFoundError('Contract not found');
      }
      req.logger.info(
        {
          action: 'signature.createPartiesBulk',
          userId: req.user?.id,
          contractId: Number(id),
          createdCount: result.createdCount,
          skippedCount: result.skippedCount,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );
      res.status(201).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.error(
        {
          action: 'signature.createPartiesBulk',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** S2 — POST /api/v1/contracts/:id/send-for-signature → fn_signature_send_for_signature */
  async sendForSignature(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'signature.sendForSignature',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const result = await signatureService.sendForSignature(req.user!.id, Number(id));
      if (!result) {
        throw new NotFoundError('Contract not found');
      }
      // Log invitations COUNT only — never plaintext tokens. The mailer is
      // the consumer; controller cannot inspect tokens in any form.
      req.logger.info(
        {
          action: 'signature.sendForSignature',
          userId: req.user?.id,
          contractId: result.contractId,
          newStatus: result.newStatus,
          invitationCount: result.invitations.length,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.error(
        {
          action: 'signature.sendForSignature',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** S6 — GET /api/v1/contracts/:id/signatures → fn_signature_list_for_contract */
  async listForContract(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'signature.listForContract',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const result = await signatureService.listForContract(
        req.user!.id,
        Number(id),
        req.user?.role ?? null,
      );
      if (!result) {
        // RLS-narrowed silently → 404 (mirrors approval.chainGetByContract pattern)
        throw new NotFoundError('Contract not found');
      }
      req.logger.info(
        {
          action: 'signature.listForContract',
          userId: req.user?.id,
          contractId: result.contractId,
          signerCount: result.signers.length,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.error(
        {
          action: 'signature.listForContract',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** S7 — POST /api/v1/signature-parties/:id/resend → fn_signature_invitation_resend */
  async resendInvitation(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'signature.resendInvitation',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as SignaturePartyIdParamInferred;
      const body = req.body as ResendInvitationDtoInferred;
      const result = await signatureService.resendInvitation(
        req.user!.id,
        Number(id),
        body.reason ?? null,
      );
      if (!result) {
        throw new NotFoundError('Signature party not found');
      }
      req.logger.info(
        {
          action: 'signature.resendInvitation',
          userId: req.user?.id,
          signaturePartyId: Number(id),
          newInvitationId: result.newInvitationId,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.error(
        {
          action: 'signature.resendInvitation',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** S8 — POST /api/v1/signature-invitations/:id/cancel → fn_signature_invitation_cancel */
  async cancelInvitation(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'signature.cancelInvitation',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as SignatureInvitationIdParamInferred;
      const body = req.body as CancelInvitationDtoInferred;
      const result = await signatureService.cancelInvitation(
        req.user!.id,
        Number(id),
        body.reason,
      );
      if (!result) {
        throw new NotFoundError('Invitation not found');
      }
      req.logger.info(
        {
          action: 'signature.cancelInvitation',
          userId: req.user?.id,
          invitationId: result.invitationId,
          contractRolledBack: result.contractRolledBack,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.error(
        {
          action: 'signature.cancelInvitation',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * R-RC2 — POST /api/v1/contracts/:id/signing-link/self
   * In-app self-service signing entry. Authenticated signer (typically a
   * recipient role) gets a fresh /sign/{token} URL by rolling their
   * existing pending|viewed|expired invitation. Caller-bound inside the
   * fn (signer_user_id OR signer_email match); 42501 if the actor is
   * not a signer on the contract; P0002 if no active invitation exists;
   * P0001 if the existing invitation is in a terminal state
   * (signed / declined / cancelled).
   */
  async resolveSigningLinkForSelf(
    req: Request,
    res: Response,
    next: NextFunction,
  ): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'signature.resolveSigningLinkForSelf',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const result = await signatureService.resolveSigningLinkForSelf(
        req.user!.id,
        Number(id),
      );
      if (!result) {
        throw new NotFoundError('No active signing invitation for this contract');
      }
      req.logger.info(
        {
          action: 'signature.resolveSigningLinkForSelf',
          userId: req.user?.id,
          contractId: Number(id),
          newInvitationId: result.newInvitationId,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      // Token plaintext is in result; pino redact masks it from request logs.
      res.status(200).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.error(
        {
          action: 'signature.resolveSigningLinkForSelf',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },
};
