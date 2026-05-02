/**
 * JWT util — sign/verify roundtrip + aud/iss validation.
 */
import { describe, it, expect, beforeAll } from 'vitest';

beforeAll(() => {
  // Ensure required env is present for env-validation
  process.env.NODE_ENV = process.env.NODE_ENV ?? 'test';
  process.env.JWT_SECRET =
    process.env.JWT_SECRET ?? 'a'.repeat(48);
  process.env.JWT_AUDIENCE = process.env.JWT_AUDIENCE ?? 'musanad-contracts';
  process.env.JWT_ISSUER = process.env.JWT_ISSUER ?? 'musanad-contracts-backend';
  process.env.DATABASE_URL =
    process.env.DATABASE_URL ?? 'postgresql://noop:noop@localhost:5432/noop';
  process.env.SMTP_HOST = process.env.SMTP_HOST ?? 'localhost';
  process.env.SMTP_PORT = process.env.SMTP_PORT ?? '1025';
  process.env.SMTP_FROM_NAME = process.env.SMTP_FROM_NAME ?? 'Test';
  process.env.SMTP_FROM_EMAIL = process.env.SMTP_FROM_EMAIL ?? 'test@example.com';
  process.env.UAE_PASS_REDIRECT_URI =
    process.env.UAE_PASS_REDIRECT_URI ?? 'http://localhost:4000/auth/uae-pass/callback';
  process.env.CORS_ORIGIN = process.env.CORS_ORIGIN ?? 'http://localhost:5173';
});

describe('jwt.util', () => {
  it('signs and verifies an access token roundtrip', async () => {
    const { validateEnv } = await import('../../src/utils/env-validation.util');
    validateEnv();
    const { signAccessToken, verifyAccessToken } = await import('../../src/utils/jwt.util');

    const token = signAccessToken({ userId: 42, role: 'Admin' });
    const payload = verifyAccessToken(token);

    expect(payload.sub).toBe(42);
    expect(payload.role).toBe('Admin');
    expect(payload.aud).toBe(process.env.JWT_AUDIENCE);
    expect(payload.iss).toBe(process.env.JWT_ISSUER);
    expect(payload.type).toBe('access');
    expect(payload.exp).toBeGreaterThan(Math.floor(Date.now() / 1000));
  });

  it('rejects an access token with wrong audience', async () => {
    const { signAccessToken, verifyAccessToken } = await import('../../src/utils/jwt.util');
    const jwt = await import('jsonwebtoken');

    // Sign with a deliberately-wrong audience
    const bad = jwt.default.sign(
      { sub: 1, role: 'User', type: 'access' },
      process.env.JWT_SECRET as string,
      {
        audience: 'wrong-aud',
        issuer: process.env.JWT_ISSUER,
        expiresIn: '15m',
      },
    );
    expect(() => verifyAccessToken(bad)).toThrow();

    // Sanity — round trip still works for the right aud
    const good = signAccessToken({ userId: 1, role: 'User' });
    expect(() => verifyAccessToken(good)).not.toThrow();
  });

  it('rejects an access token with wrong issuer', async () => {
    const { verifyAccessToken } = await import('../../src/utils/jwt.util');
    const jwt = await import('jsonwebtoken');

    const bad = jwt.default.sign(
      { sub: 1, role: 'User', type: 'access' },
      process.env.JWT_SECRET as string,
      {
        audience: process.env.JWT_AUDIENCE,
        issuer: 'wrong-iss',
        expiresIn: '15m',
      },
    );
    expect(() => verifyAccessToken(bad)).toThrow();
  });

  it('signs and verifies a refresh token, includes jti', async () => {
    const { signRefreshToken, verifyRefreshToken } = await import('../../src/utils/jwt.util');

    const { token, jti } = signRefreshToken({ userId: 7 });
    expect(jti.length).toBeGreaterThan(8);

    const payload = verifyRefreshToken(token);
    expect(payload.sub).toBe(7);
    expect(payload.type).toBe('refresh');
    expect(payload.jti).toBe(jti);
  });

  it('hashTokenForBlacklist produces hex sha256', async () => {
    const { hashTokenForBlacklist } = await import('../../src/utils/jwt.util');
    const a = hashTokenForBlacklist('hello');
    const b = hashTokenForBlacklist('hello');
    const c = hashTokenForBlacklist('world');
    expect(a).toBe(b);
    expect(a).not.toBe(c);
    expect(a).toMatch(/^[a-f0-9]{64}$/);
  });
});
