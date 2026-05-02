/**
 * Auth controller — login, logout, refresh, UAE Pass.
 *
 * Every method follows the mandatory template (skill-logging-patterns.md
 * Section 3): entry log on first line, exit log immediately before
 * res.json(), error log + next(error) in catch.
 *
 * Sensitive fields (password, refreshToken) are NEVER passed to req.logger.
 * Pino redaction also catches them, but we don't rely on that as the only
 * defense.
 *
 * Security patches landed (Codex review, 2026-05-02):
 *   - CRX-1: refresh rotation now uses fn_auth_blacklist_if_absent for
 *            atomic check+insert (closes TOCTOU race).
 *   - CRX-2: login now performs a dummy bcrypt.compare on the unknown-email
 *            arm to equalize timing (mitigates email enumeration).
 *   - CRX-3: UAE Pass `state` is now stored at /initiate and consumed at
 *            /callback (single-use, 5-min TTL).
 *   - CRX-10: misleading "// SECURITY: ..." comments removed where the impl
 *             didn't enforce the claimed property.
 */
import crypto from 'node:crypto';
import bcrypt from 'bcryptjs';
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { logger as rootLogger } from '../utils/logger.util';
import {
  decodeUnsafe,
  hashTokenForBlacklist,
  signAccessToken,
  signRefreshToken,
  verifyRefreshToken,
} from '../utils/jwt.util';
import { comparePassword } from '../utils/password.util';
import {
  ApiError,
  InvalidCredentialsError,
  LockedError,
  UnauthorizedError,
} from '../utils/errors.util';
import { env } from '../utils/env-validation.util';
import { getUAEPassProvider } from '../integrations/uae-pass';
import { consumeState, storeState } from '../integrations/uae-pass/state-store';
import type {
  LoginUserRecord,
  RecordLoginFailureResult,
  User,
} from '../types/api.types';

/**
 * Pre-computed bcrypt hash used to equalize login timing on the
 * unknown-email path (CRX-2). The actual plaintext value here is irrelevant;
 * it just needs to be a valid bcrypt hash so bcrypt.compare runs the same
 * KDF rounds as the wrong-password path.
 *
 * Generated synchronously at module load — happens once, costs ~120ms once,
 * has no impact on hot-path latency.
 */
const DUMMY_BCRYPT_HASH = bcrypt.hashSync(
  'dummy_for_timing_normalization_xxxxxxxxxxxx',
  12,
);

/**
 * Refresh-token blacklist result (CRX-1).
 * Returned by fn_auth_blacklist_if_absent: `inserted: true` means THIS call
 * actually wrote the row; `inserted: false` means a concurrent caller (or
 * a prior call) already blacklisted it — controller MUST reject.
 */
interface BlacklistIfAbsentResult {
  inserted: boolean;
  reason?: string;
}

interface LoginBody {
  email: string;
  password: string;
}

interface RefreshBody {
  refreshToken: string;
}

interface LogoutBody {
  refreshToken: string;
}

export const authController = {
  /**
   * POST /api/v1/auth/login
   */
  async login(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'auth.login', method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const { email, password } = req.body as LoginBody;
      const e = env();

      // 1. Lookup user
      const userRecord = await db.callFunction<LoginUserRecord | null>(
        'fn_auth_get_user_for_login',
        [email],
      );

      // CRX-2: Mitigate email enumeration. If no user row was found, still
      // run a bcrypt compare against a fixed dummy hash so the response
      // time matches the wrong-password path. Both arms throw the same
      // generic InvalidCredentialsError — never disclose which arm executed.
      // The userRecord contains passwordHash — pino redaction catches it,
      // but we deliberately never pass this object to req.logger.
      if (!userRecord) {
        await bcrypt.compare(password, DUMMY_BCRYPT_HASH); // discard result
        req.logger.warn(
          { action: 'auth.login', reason: 'unknown_email', duration: Date.now() - startTime },
          'Login failed',
        );
        throw new InvalidCredentialsError('Invalid email or password');
      }

      // 2. Lockout check
      if (userRecord.lockedUntil && new Date(userRecord.lockedUntil).getTime() > Date.now()) {
        req.logger.warn(
          {
            action: 'auth.login',
            userId: userRecord.id,
            reason: 'locked',
            duration: Date.now() - startTime,
          },
          'Login blocked — account locked',
        );
        throw new LockedError('Account locked. Try again later.');
      }

      // 3. Active check (already filtered by fn_, but defensive)
      if (!userRecord.isActive) {
        throw new InvalidCredentialsError('Invalid email or password');
      }

      // 4. bcrypt compare
      const ok = await comparePassword(password, userRecord.passwordHash);
      if (!ok) {
        const failResult = await db.callFunction<RecordLoginFailureResult>(
          'fn_auth_record_login_failure',
          [userRecord.id, e.AUTH_MAX_FAILED_ATTEMPTS, e.AUTH_LOCKOUT_MINUTES],
        );
        req.logger.warn(
          {
            action: 'auth.login',
            userId: userRecord.id,
            reason: 'bad_password',
            attempts: failResult.loginAttempts,
            isLocked: failResult.isLocked,
            duration: Date.now() - startTime,
          },
          'Login failed',
        );
        if (failResult.isLocked) {
          throw new LockedError('Account locked due to too many failed attempts');
        }
        throw new InvalidCredentialsError('Invalid email or password');
      }

      // 5. Record success (resets attempts, sets last_login_at)
      await db.callFunction('fn_auth_record_login_success', [userRecord.id]);

      // 6. Sign tokens
      const accessToken = signAccessToken({ userId: userRecord.id, role: userRecord.role.name });
      const { token: refreshToken } = signRefreshToken({ userId: userRecord.id });

      // 7. Build AuthUser response (lookup permissions)
      const fullUser = await db.callFunction<User | null>('fn_user_get_by_id', [userRecord.id], {
        actorId: userRecord.id,
      });
      if (!fullUser) {
        throw new InvalidCredentialsError('Invalid email or password');
      }
      const authUser = {
        id: fullUser.id,
        email: fullUser.email,
        firstName: fullUser.firstName,
        lastName: fullUser.lastName,
        role: fullUser.role,
        permissions: fullUser.permissions,
      };

      req.logger.info(
        {
          action: 'auth.login',
          userId: userRecord.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );

      res.status(200).json({
        accessToken,
        refreshToken,
        user: authUser,
      });
    } catch (error) {
      req.logger.error(
        {
          action: 'auth.login',
          duration: Date.now() - startTime,
          errorType:
            error instanceof ApiError
              ? error.code
              : error instanceof Error
                ? error.name
                : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * POST /api/v1/auth/logout
   */
  async logout(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'auth.logout', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const { refreshToken } = req.body as LogoutBody;
      const userId = req.user!.id;

      // Decode (unsafe is fine here — we only need exp for blacklist record).
      // Verification of the access token already happened in `authenticate`.
      const decoded = decodeUnsafe(refreshToken);
      const expSeconds = decoded?.exp ?? Math.floor(Date.now() / 1000) + 7 * 24 * 3600;
      const expiresAt = new Date(expSeconds * 1000).toISOString();

      const tokenHash = hashTokenForBlacklist(refreshToken);
      await db.callFunction('fn_auth_blacklist_token', [tokenHash, userId, expiresAt], {
        actorId: userId,
      });

      req.logger.info(
        { action: 'auth.logout', userId, duration: Date.now() - startTime, statusCode: 200 },
        'Controller exit',
      );

      res.status(200).json({ success: true, message: 'Logged out' });
    } catch (error) {
      req.logger.error(
        {
          action: 'auth.logout',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType:
            error instanceof ApiError
              ? error.code
              : error instanceof Error
                ? error.name
                : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * POST /api/v1/auth/refresh
   *
   * Refresh-token rotation (OWASP / RFC 6749 best practice).
   *
   * CRX-1 fix: the previous implementation did a separate
   * fn_auth_check_token_blacklist + fn_auth_blacklist_token, which left a
   * TOCTOU window where two concurrent refresh calls with the same token
   * both passed the check and both minted new sessions. The new flow uses
   * fn_auth_blacklist_if_absent: a single atomic INSERT ... ON CONFLICT
   * DO NOTHING that returns inserted=true ONLY when this call actually
   * wrote the row. Any concurrent caller sees inserted=false and is
   * rejected — only one rotation can succeed per refresh token.
   *
   * Order of operations:
   *   1. Verify refresh JWT (signature + aud/iss/exp).
   *   2. Confirm user is still active (fn_user_get_by_id).
   *   3. ATOMICALLY blacklist the OLD refresh token's hash. If
   *      `inserted: false` (another caller beat us OR token was already
   *      revoked), 401 — this is the rotation-based theft detection
   *      signal.
   *   4. Sign new access + new refresh pair and return.
   *
   * The client MUST overwrite its stored refresh token with the new one;
   * any subsequent attempt to reuse the old refresh token will fail at
   * step 3 (it's blacklisted from this rotation).
   */
  async refresh(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'auth.refresh', method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const { refreshToken } = req.body as RefreshBody;

      // 1. Verify refresh JWT (aud, iss, exp validated)
      let payload;
      try {
        payload = verifyRefreshToken(refreshToken);
      } catch {
        throw new UnauthorizedError('Invalid or expired refresh token');
      }

      // 2. User active check via fn_user_get_by_id (cheap; fails fast before
      //    we touch the blacklist).
      const user = await db.callFunction<User | null>('fn_user_get_by_id', [payload.sub], {
        actorId: payload.sub,
      });
      if (!user || user.isActive === false) {
        throw new UnauthorizedError('User no longer active');
      }

      // 3. ATOMIC blacklist (CRX-1). Either we win the race and `inserted`
      //    is true, or someone else already blacklisted this jti and we
      //    reject. Single SQL statement under ON CONFLICT DO NOTHING.
      const oldTokenHash = hashTokenForBlacklist(refreshToken);
      const oldExpiresAt = new Date(payload.exp * 1000).toISOString();
      const blacklistResult = await db.callFunction<BlacklistIfAbsentResult>(
        'fn_auth_blacklist_if_absent',
        [oldTokenHash, user.id, oldExpiresAt, 'refresh_rotation'],
        { actorId: user.id },
      );
      if (!blacklistResult.inserted) {
        // Either: (a) this token was already blacklisted (logout / earlier
        // rotation), or (b) a concurrent refresh request beat us to the
        // INSERT. In both cases the right answer is the same — reject.
        throw new UnauthorizedError('Refresh token has been revoked or already rotated');
      }

      // 4. Sign NEW access + NEW refresh tokens (fresh jti on the refresh).
      const accessToken = signAccessToken({ userId: user.id, role: user.role.name });
      const { token: newRefreshToken } = signRefreshToken({ userId: user.id });

      req.logger.info(
        {
          action: 'auth.refresh',
          userId: user.id,
          rotated: true,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );

      res.status(200).json({ accessToken, refreshToken: newRefreshToken });
    } catch (error) {
      req.logger.error(
        {
          action: 'auth.refresh',
          duration: Date.now() - startTime,
          errorType:
            error instanceof ApiError
              ? error.code
              : error instanceof Error
                ? error.name
                : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * POST /api/v1/auth/uae-pass/initiate
   * NOT in original M0 OpenAPI — added per decisions.md G3.
   *
   * CRX-3: state is generated server-side (32 random hex bytes), persisted
   * via state-store with a 5-min TTL, and returned to the client. The
   * /callback handler MUST present the same state value, where it is
   * consumed (single-use) and matched.
   */
  async uaePassInitiate(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'auth.uaePassInitiate', method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      // 32 hex chars = 128 bits of entropy. Sufficient for a CSRF nonce.
      const state = crypto.randomBytes(32).toString('hex');
      storeState(state); // 5-min TTL; single-use on callback
      const provider = getUAEPassProvider();
      const { authorizeUrl } = provider.initiateAuth(state);

      req.logger.info(
        {
          action: 'auth.uaePassInitiate',
          provider: provider.name,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );

      res.status(200).json({ authorizeUrl, state });
    } catch (error) {
      req.logger.error(
        {
          action: 'auth.uaePassInitiate',
          duration: Date.now() - startTime,
          errorType:
            error instanceof ApiError
              ? error.code
              : error instanceof Error
                ? error.name
                : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * POST /api/v1/auth/uae-pass/callback
   * Mock returns synthetic identity; live not implemented.
   * Real impl: map identity → local user, issue JWTs.
   *
   * CRX-3: validates `state` against the in-memory state-store before
   * exchanging the code with the provider. Single-use — a second callback
   * with the same state value is rejected (replay protection).
   */
  async uaePassCallback(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'auth.uaePassCallback', method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { code, state } = req.body as { code: string; state: string };

      // CRX-3: consume + validate state BEFORE talking to the provider.
      // consumeState is single-use: a second callback with the same state
      // sees null and is rejected.
      const stateRecord = consumeState(state);
      if (stateRecord === null) {
        throw new UnauthorizedError('Invalid or expired state parameter');
      }

      const provider = getUAEPassProvider();
      const identity = await provider.handleCallback(code, state);

      // Mock-only: return the identity payload. The real impl would map
      // identity.sub → local user (via a uae_pass_link table) and issue
      // JWTs the same way login does.
      req.logger.info(
        {
          action: 'auth.uaePassCallback',
          provider: provider.name,
          uaePassSub: identity.sub,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );

      res.status(200).json({
        success: true,
        provider: provider.name,
        // identity.raw is sensitive — surface a redacted projection
        identity: {
          sub: identity.sub,
          fullNameEn: identity.fullNameEn,
          fullNameAr: identity.fullNameAr,
          email: identity.email,
          trustLevel: identity.trustLevel,
        },
      });
    } catch (error) {
      req.logger.error(
        {
          action: 'auth.uaePassCallback',
          duration: Date.now() - startTime,
          errorType:
            error instanceof ApiError
              ? error.code
              : error instanceof Error
                ? error.name
                : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },
};

// Suppress unused root-logger warning — kept for symmetry with controller pattern
void rootLogger;
