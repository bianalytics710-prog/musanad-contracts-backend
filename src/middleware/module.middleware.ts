/**
 * CR-V — Module-enabled middleware.
 *
 * requireModuleEnabled(moduleKey) reads req.user.effectiveModules (populated by
 * auth.middleware.ts from fn_user_get_by_id which folds in fn_user_effective_modules
 * per migration 345). If the moduleKey is NOT in that array the request receives a
 * 404 (not 403) — making the route feel like it doesn't exist for this customer,
 * not "you don't have permission".
 *
 * Use AFTER authenticate + rlsMiddleware in the route chain:
 *
 *   router.use('/financial/trade-margin', authenticate, rlsMiddleware,
 *              requireModuleEnabled('financial.trade_margin'), tradeMarginRouter);
 *
 * Pino logging on block: captures userId, moduleKey, and original URL so we can
 * correlate module-disable events in the audit stream without exposing anything
 * sensitive.
 *
 * Reference:
 *   Product-Module-Toggle-Reference.md §3 enforcement point #3
 *   wondrous-cooking-rivest.md §"Backend changes" §2
 */
import type { NextFunction, Request, Response } from 'express';
import { UnauthorizedError } from '../utils/errors.util';

/**
 * Returns an Express middleware that blocks the request with a 404 if the
 * authenticated user's effectiveModules does not contain `moduleKey`.
 *
 * The 404 body matches the existing error-envelope shape:
 *   { success: false, error: { code: 'MODULE_DISABLED', message: '...' }, moduleKey, requestId }
 *
 * The error is emitted directly (not via next(err)) so we can include the
 * moduleKey in the JSON body without the global error middleware stripping it.
 * We still log it via req.logger so Pino captures it.
 */
export const requireModuleEnabled =
  (moduleKey: string) =>
  (req: Request, res: Response, next: NextFunction): void => {
    if (!req.user) {
      // Should not happen — requireModuleEnabled must be placed after authenticate.
      next(new UnauthorizedError('Authentication required'));
      return;
    }

    const effectiveModules = req.user.effectiveModules ?? [];

    if (!effectiveModules.includes(moduleKey)) {
      req.logger?.info(
        {
          action: 'module.disabled',
          userId: req.user.id,
          moduleKey,
          route: req.originalUrl,
        },
        'module disabled, route 404',
      );

      res.status(404).json({
        success: false,
        error: {
          code: 'MODULE_DISABLED',
          message: 'This module is not available for your account',
        },
        moduleKey,
        requestId: req.requestId,
      });
      return;
    }

    next();
  };
