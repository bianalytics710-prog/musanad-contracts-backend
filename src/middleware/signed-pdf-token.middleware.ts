/**
 * Signed-PDF-token middleware (M4 / S5).
 *
 * Validates an HMAC-signed JWT for the PUBLIC endpoint
 *   POST /api/v1/ai/regulatory-impact-summary
 *
 * Per Q3 Option A (gate2-decisions.md): the underlying fn_ remains
 * neondb_owner-only DEFINER; this middleware is the authentication boundary.
 *
 * On success: attaches `req.signedPdfToken` (decoded claims). Controller may
 * read this for entity_id / scope binding.
 *
 * On failure: forwards UnauthorizedError (401) — never leaks decode details.
 *
 * Sensitive data:
 *   - Token NEVER logged. logger.util.ts redacts both
 *     'X-Signed-Pdf-Token' header and 'signedToken' body field.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, UnauthorizedError } from '../utils/errors.util';
import {
  extractSignedPdfToken,
  verifySignedPdfToken,
} from '../services/ai/_shared/signed-pdf-token-validator';
import type { SignedPdfTokenClaims } from '../types/ai.types';

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      /** Decoded signed-PDF-token claims (M4 / S5). */
      signedPdfToken?: SignedPdfTokenClaims;
    }
  }
}

export const verifySignedPdfTokenMiddleware = (
  req: Request,
  _res: Response,
  next: NextFunction,
): void => {
  const token = extractSignedPdfToken({
    headers: req.headers as Record<string, string | string[] | undefined>,
    body: req.body,
  });
  if (!token) {
    next(new UnauthorizedError('Missing signed-PDF-token'));
    return;
  }
  try {
    const claims = verifySignedPdfToken(token);
    req.signedPdfToken = claims;
    next();
  } catch (err) {
    if (err instanceof ApiError) {
      next(err);
      return;
    }
    next(new UnauthorizedError('Invalid signed-PDF-token'));
  }
};
