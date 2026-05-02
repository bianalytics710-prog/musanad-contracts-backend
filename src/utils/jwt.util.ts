/**
 * JWT helpers. Validates aud/iss/exp on EVERY verify call (CLAUDE.md §8).
 *
 * Issues two token types:
 *   - access (15m default): contains sub, role, type='access'
 *   - refresh (7d default): contains sub, jti, type='refresh'
 *
 * The `jti` on refresh tokens enables SHA-256-hash blacklisting in the
 * token_blacklist table.
 */
import jwt from 'jsonwebtoken';
import type { SignOptions } from 'jsonwebtoken';
import crypto from 'node:crypto';
import { v4 as uuidv4 } from 'uuid';
import { env } from './env-validation.util';

export interface AccessTokenPayload {
  sub: number; // user.id
  role: string; // role.name
  aud: string;
  iss: string;
  iat: number;
  exp: number;
  type: 'access';
}

export interface RefreshTokenPayload {
  sub: number;
  aud: string;
  iss: string;
  iat: number;
  exp: number;
  jti: string;
  type: 'refresh';
}

export type AnyJwtPayload = AccessTokenPayload | RefreshTokenPayload;

/**
 * Sign an access token (short TTL).
 */
export const signAccessToken = (params: { userId: number; role: string }): string => {
  const e = env();
  const opts: SignOptions = {
    audience: e.JWT_AUDIENCE,
    issuer: e.JWT_ISSUER,
    expiresIn: e.JWT_ACCESS_TTL as SignOptions['expiresIn'],
    algorithm: 'HS256',
  };
  return jwt.sign(
    {
      sub: String(params.userId),
      role: params.role,
      type: 'access',
    },
    e.JWT_SECRET,
    opts,
  );
};

/**
 * Sign a refresh token (long TTL). Includes a `jti` for blacklisting.
 */
export const signRefreshToken = (params: { userId: number }): { token: string; jti: string } => {
  const e = env();
  const jti = uuidv4();
  const opts: SignOptions = {
    audience: e.JWT_AUDIENCE,
    issuer: e.JWT_ISSUER,
    expiresIn: e.JWT_REFRESH_TTL as SignOptions['expiresIn'],
    algorithm: 'HS256',
    jwtid: jti,
  };
  const token = jwt.sign(
    {
      sub: String(params.userId),
      type: 'refresh',
    },
    e.JWT_SECRET,
    opts,
  );
  return { token, jti };
};

/**
 * Verify an access token. Throws on any failure (expired, invalid signature,
 * aud/iss mismatch, malformed). Caller maps to 401.
 */
export const verifyAccessToken = (token: string): AccessTokenPayload => {
  const e = env();
  const decoded = jwt.verify(token, e.JWT_SECRET, {
    audience: e.JWT_AUDIENCE,
    issuer: e.JWT_ISSUER,
    algorithms: ['HS256'],
  });
  if (typeof decoded === 'string' || decoded === null || typeof decoded !== 'object') {
    throw new Error('Invalid access token payload');
  }
  const payload = decoded as Record<string, unknown>;
  if (payload.type !== 'access') {
    throw new Error('Token type is not access');
  }
  return {
    sub: Number(payload.sub),
    role: String(payload.role ?? ''),
    aud: String(payload.aud ?? ''),
    iss: String(payload.iss ?? ''),
    iat: Number(payload.iat),
    exp: Number(payload.exp),
    type: 'access',
  };
};

/**
 * Verify a refresh token. Same aud/iss/exp checks. Caller still must
 * SHA-256(token) and call fn_auth_check_token_blacklist.
 */
export const verifyRefreshToken = (token: string): RefreshTokenPayload => {
  const e = env();
  const decoded = jwt.verify(token, e.JWT_SECRET, {
    audience: e.JWT_AUDIENCE,
    issuer: e.JWT_ISSUER,
    algorithms: ['HS256'],
  });
  if (typeof decoded === 'string' || decoded === null || typeof decoded !== 'object') {
    throw new Error('Invalid refresh token payload');
  }
  const payload = decoded as Record<string, unknown>;
  if (payload.type !== 'refresh') {
    throw new Error('Token type is not refresh');
  }
  return {
    sub: Number(payload.sub),
    aud: String(payload.aud ?? ''),
    iss: String(payload.iss ?? ''),
    iat: Number(payload.iat),
    exp: Number(payload.exp),
    jti: String(payload.jti ?? ''),
    type: 'refresh',
  };
};

/**
 * SHA-256 a refresh token before storage in token_blacklist.
 * The raw token is never persisted.
 */
export const hashTokenForBlacklist = (token: string): string =>
  crypto.createHash('sha256').update(token).digest('hex');

/**
 * Decode a JWT without verifying — used to extract `exp` for setting the
 * token_blacklist.expires_at column on logout. Returns null on parse error.
 */
export const decodeUnsafe = (token: string): { exp?: number; sub?: string } | null => {
  try {
    const decoded = jwt.decode(token);
    if (!decoded || typeof decoded === 'string') return null;
    const exp = typeof decoded.exp === 'number' ? decoded.exp : undefined;
    const sub = typeof decoded.sub === 'string' ? decoded.sub : undefined;
    const result: { exp?: number; sub?: string } = {};
    if (exp !== undefined) result.exp = exp;
    if (sub !== undefined) result.sub = sub;
    return result;
  } catch {
    return null;
  }
};
