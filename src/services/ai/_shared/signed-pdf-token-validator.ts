/**
 * Signed-PDF-token validator (S5).
 *
 * The S5 endpoint POST /api/v1/ai/regulatory-impact-summary is PUBLIC at the
 * Express level (verify_jwt: false). Per Q3 Option A, the controller-mediated
 * signed-PDF-token is HMAC-validated at the Express middleware layer; the
 * underlying fn_ai_regulatory_impact_summary_get is neondb_owner-only DEFINER.
 *
 * Token format: standard JWT (HS256) with claims:
 *   - aud='regulatory-impact-pdf'
 *   - iss=SIGNED_PDF_TOKEN_ISSUER (env)
 *   - exp <= now+1h (short-lived, per-PDF-render)
 *   - sub: caller-defined identifier (e.g., regulatory_update id when M5 ships)
 *   - jti: optional nonce for replay protection (opaque — no DB blacklist for M4)
 *
 * Sensitive data:
 *   - signedToken NEVER logged. Pino redact path covers req.body.signedToken
 *     and 'X-Signed-Pdf-Token' header.
 */
import jwt from 'jsonwebtoken';
import { env } from '../../../utils/env-validation.util';
import {
  ServiceUnavailableError,
  UnauthorizedError,
} from '../../../utils/errors.util';
import type { SignedPdfTokenClaims } from '../../../types/ai.types';

const SIGNED_PDF_AUDIENCE = 'regulatory-impact-pdf' as const;

/**
 * Extract the signed-PDF-token from the request. Accepted locations:
 *   1. `Authorization: Bearer <token>` header
 *   2. `X-Signed-Pdf-Token: <token>` header
 *   3. `signedToken` field in the JSON body (already validated by Zod schema
 *      before middleware fires for that source — kept as fallback for
 *      query-string-driven PDF render flows).
 *
 * Returns null when not found — the middleware itself maps that to 401.
 */
export const extractSignedPdfToken = (req: {
  headers: Record<string, string | string[] | undefined>;
  body?: unknown;
}): string | null => {
  const auth = req.headers.authorization ?? req.headers.Authorization;
  if (typeof auth === 'string') {
    const match = auth.match(/^Bearer\s+(.+)$/i);
    if (match && match[1]) return match[1].trim();
  }
  const explicit =
    req.headers['x-signed-pdf-token'] ?? req.headers['X-Signed-Pdf-Token'];
  if (typeof explicit === 'string' && explicit.length > 0) return explicit.trim();
  // Fallback: signedToken field on req.body (already validated max length by Zod).
  if (req.body && typeof req.body === 'object' && req.body !== null) {
    const body = req.body as Record<string, unknown>;
    const t = body.signedToken;
    if (typeof t === 'string' && t.length > 0) return t.trim();
  }
  return null;
};

/**
 * Verify the token. Throws ApiError subclasses on failure:
 *   - ServiceUnavailableError when SIGNED_PDF_TOKEN_SECRET is not configured
 *     (prod misconfig — log and 503 rather than 401, so operators see it).
 *   - UnauthorizedError on invalid signature, aud/iss mismatch, expiry.
 */
export const verifySignedPdfToken = (token: string): SignedPdfTokenClaims => {
  const e = env();
  if (!e.SIGNED_PDF_TOKEN_SECRET) {
    throw new ServiceUnavailableError('Signed-PDF-token validation is not configured');
  }
  let decoded: unknown;
  try {
    decoded = jwt.verify(token, e.SIGNED_PDF_TOKEN_SECRET, {
      audience: e.SIGNED_PDF_TOKEN_AUDIENCE,
      issuer: e.SIGNED_PDF_TOKEN_ISSUER,
      algorithms: ['HS256'],
    });
  } catch (_err) {
    throw new UnauthorizedError('Invalid or expired signed-PDF-token');
  }
  if (typeof decoded !== 'object' || decoded === null) {
    throw new UnauthorizedError('Invalid signed-PDF-token payload');
  }
  const payload = decoded as Record<string, unknown>;
  // Defense-in-depth: re-check aud (jwt.verify already enforced it; we encode
  // the constant claim-shape for downstream consumers).
  if (payload.aud !== SIGNED_PDF_AUDIENCE) {
    throw new UnauthorizedError('Token audience mismatch');
  }
  return {
    sub: String(payload.sub ?? ''),
    aud: SIGNED_PDF_AUDIENCE,
    iss: String(payload.iss ?? ''),
    iat: Number(payload.iat),
    exp: Number(payload.exp),
    ...(typeof payload.jti === 'string' ? { jti: payload.jti } : {}),
  };
};
