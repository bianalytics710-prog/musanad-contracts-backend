/**
 * Authentication & authorisation middleware.
 *
 *   - authenticate: verifies the bearer access token (aud/iss/exp), looks up
 *     the user via fn_user_get_by_id, attaches req.user.
 *   - authorise(permissionCodes): requires req.user.permissions to be a
 *     SUPERSET of the supplied codes. 403 otherwise.
 *
 * Permission CODES (not role names) are the canonical identifier — see
 * Contract Generator design note #2 / Permission interface.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ForbiddenError, UnauthorizedError } from '../utils/errors.util';
import { verifyAccessToken } from '../utils/jwt.util';
import type { User } from '../types/api.types';
import type { AuthUserContext } from '../types/express';

const extractBearer = (req: Request): string | null => {
  const header = req.headers.authorization ?? req.headers.Authorization;
  if (typeof header !== 'string') return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  return match ? (match[1] ?? '').trim() : null;
};

export const authenticate = async (
  req: Request,
  _res: Response,
  next: NextFunction,
): Promise<void> => {
  const token = extractBearer(req);
  if (!token) {
    next(new UnauthorizedError('Missing or invalid Authorization header'));
    return;
  }

  let payload;
  try {
    payload = verifyAccessToken(token);
  } catch (err) {
    req.logger?.warn(
      {
        action: 'auth.verify_failed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'JWT verification failed',
    );
    next(new UnauthorizedError('Invalid or expired access token'));
    return;
  }

  // Lookup user — confirms isActive and refreshes the permission set.
  let user: User | null;
  try {
    user = await db.callFunction<User | null>('fn_user_get_by_id', [payload.sub], {
      // For this lookup, set the GUC so the user_select_self_or_capability
      // RLS policy permits the read.
      actorId: payload.sub,
    });
  } catch (err) {
    req.logger?.error(
      {
        action: 'auth.user_lookup_failed',
        userId: payload.sub,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to load user during authentication',
    );
    next(new UnauthorizedError('Authentication failed'));
    return;
  }

  if (!user || user.isActive === false) {
    next(new UnauthorizedError('User no longer active'));
    return;
  }

  const ctx: AuthUserContext = {
    id: user.id,
    role: user.role.name,
    email: user.email,
    permissions: user.permissions ?? [],
  };
  req.user = ctx;
  req.authUserId = ctx.id;

  next();
};

/**
 * Require the authenticated user to hold ALL of the supplied permission codes.
 * Use AFTER `authenticate`. If permissionCodes is empty, the middleware is a
 * no-op gate that just enforces "logged in".
 */
export const authorise =
  (permissionCodes: ReadonlyArray<string>) =>
  (req: Request, _res: Response, next: NextFunction): void => {
    if (!req.user) {
      next(new UnauthorizedError('Authentication required'));
      return;
    }
    if (permissionCodes.length === 0) {
      next();
      return;
    }
    const have = new Set(req.user.permissions);
    const missing = permissionCodes.filter((p) => !have.has(p));
    if (missing.length > 0) {
      req.logger?.warn(
        {
          action: 'auth.forbidden',
          userId: req.user.id,
          missing,
        },
        'Caller missing required permission(s)',
      );
      next(new ForbiddenError('Insufficient permissions'));
      return;
    }
    next();
  };

/**
 * Variant: requires the authenticated user to hold AT LEAST ONE of the
 * supplied permission codes. Use for endpoints whose access is granted by
 * any of several scoped permissions (e.g. contract.read.all OR
 * contract.read.department OR contract.read.own).
 */
export const authoriseAnyOf =
  (permissionCodes: ReadonlyArray<string>) =>
  (req: Request, _res: Response, next: NextFunction): void => {
    if (!req.user) {
      next(new UnauthorizedError('Authentication required'));
      return;
    }
    if (permissionCodes.length === 0) {
      next();
      return;
    }
    const have = new Set(req.user.permissions);
    const ok = permissionCodes.some((p) => have.has(p));
    if (!ok) {
      req.logger?.warn(
        {
          action: 'auth.forbidden',
          userId: req.user.id,
          requiredAnyOf: permissionCodes,
        },
        'Caller missing all required permission(s)',
      );
      next(new ForbiddenError('Insufficient permissions'));
      return;
    }
    next();
  };

/**
 * Variant: requires EITHER the caller to be the user themselves (id match
 * on req.params.id) OR to hold one of the listed permission codes. Used by
 * GET/PUT /users/:id where self-edits are allowed for limited fields.
 */
export const authoriseSelfOr =
  (permissionCodes: ReadonlyArray<string>) =>
  (req: Request, _res: Response, next: NextFunction): void => {
    if (!req.user) {
      next(new UnauthorizedError('Authentication required'));
      return;
    }
    const targetIdRaw = req.params.id;
    const targetId = targetIdRaw !== undefined ? Number(targetIdRaw) : NaN;
    if (Number.isFinite(targetId) && targetId === req.user.id) {
      next();
      return;
    }
    const have = new Set(req.user.permissions);
    const ok = permissionCodes.some((p) => have.has(p));
    if (!ok) {
      next(new ForbiddenError('Insufficient permissions'));
      return;
    }
    next();
  };
