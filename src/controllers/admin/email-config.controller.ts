/**
 * CR-C — Admin Email Server Config Controller (S14).
 *
 *   GET   /api/v1/admin/email-config            → composed SmtpConfig
 *   PATCH /api/v1/admin/email-config            → patches email.* keys
 *   POST  /api/v1/admin/email-config/test-send  → composes SMTP transport, sends, times
 *
 * Compound permission gate (per ep_email_config_patch contract):
 *   email.config.manage AND settings.write
 *
 * Route layer enforces email.config.manage via authorise(['email.config.manage']);
 * the controller additionally checks settings.write on PATCH + test-send to
 * keep the AND semantics — mirrors the contract description.
 *
 * authPassRef in PATCH body is WRITE-ONLY: when undefined the existing value
 * is retained per AC-S14-07. The Pino redact list (logger.util.ts) covers
 * authPassRef + auth_pass_ref + smtp_pass + authPassRef so no controller
 * log path leaks the secret.
 */
import type { NextFunction, Request, Response } from 'express';
import {
  ApiError,
  ConflictError,
  ForbiddenError,
  ServiceUnavailableError,
  ValidationError,
} from '../../utils/errors.util';
import * as svc from '../../services/admin-email-config.service';
import type {
  EmailConfigPatchBodyInferred,
  EmailTestSendBodyInferred,
} from '../../schemas/admin-email-config.schemas';
import type { EmailConfigPatchDto } from '../../types/admin-email-config.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

/**
 * Express GatewayTimeoutError surrogate — the codebase doesn't ship a 504
 * class, so we use ServiceUnavailableError (503) as the closest semantic
 * match per the existing error hierarchy. The error code 'smtp_timeout'
 * makes the failure mode explicit at the API envelope level.
 *
 * (api-contracts.json calls for 504 'gateway_timeout' on AC-S14-04. If the
 * codebase later adds a GatewayTimeoutError, swap here.)
 */
const smtpTimeoutError = (): ApiError =>
  new ServiceUnavailableError('smtp_timeout');

const requireSettingsWrite = (req: Request): void => {
  const have = new Set(req.user?.permissions ?? []);
  if (!have.has('settings.write')) {
    throw new ForbiddenError('settings.write permission required');
  }
};

export const adminEmailConfigController = {
  async get(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.emailConfig.get',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const result = await svc.getEmailConfig(req.user!.id);
      req.logger.info(
        {
          action: 'admin.emailConfig.get',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.emailConfig.get',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async patch(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.emailConfig.patch',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      requireSettingsWrite(req);
      const body = req.body as EmailConfigPatchBodyInferred;
      // Cast through EmailConfigPatchDto — Zod schema's z.enum() preserves the
      // string-literal union at runtime but TS infers `string` from the
      // schema's string-tuple constructor; this cast restores the narrowed
      // type without a runtime check (the schema already enforced the union).
      const result = await svc.patchEmailConfig(
        req.user!.id,
        body as EmailConfigPatchDto,
      );
      req.logger.info(
        {
          action: 'admin.emailConfig.patch',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.emailConfig.patch',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async testSend(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.emailConfig.testSend',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
        // recipient logged separately as a non-PII identifier
      },
      'Controller entry',
    );
    try {
      const body = (req.body ?? {}) as EmailTestSendBodyInferred;
      // Q5 default-to-admin — when no recipient supplied, fall back to the
      // calling admin's own email address.
      const recipient = body?.recipient ?? req.user?.email ?? '';
      if (!recipient) {
        throw new ValidationError('recipient required (calling user has no email)', {
          recipient: 'invalid_email',
        });
      }
      const result = await svc.sendTestEmail(req.user!.id, recipient);

      if (!result.sent) {
        // Map failure modes to HTTP envelope per AC-S14-04 / AC-S14-05.
        if (result.error === 'email_disabled') {
          throw new ConflictError('email_disabled');
        }
        if (result.error === 'smtp_timeout') {
          throw smtpTimeoutError();
        }
        // Other delivery failures — surface as 503 with the error preserved.
        throw new ServiceUnavailableError(result.error ?? 'smtp_send_failed');
      }

      req.logger.info(
        {
          action: 'admin.emailConfig.testSend',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          deliveryMs: result.deliveryMs,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.emailConfig.testSend',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },
};
