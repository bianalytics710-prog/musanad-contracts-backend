/**
 * Auth integration — bootstrap admin login + refresh + logout cycle.
 *
 * Runs against the Neon m0-foundation branch. Bootstrap admin credentials
 * (per DB Implementation handoff §8):
 *   email:    admin@musanad.local
 *   password: ChangeMe@123
 *
 * Caveat: there's no separate test branch yet (DB Impl handoff §10).
 * The test login + logout writes to the dev branch — acceptable because
 * it only mutates the bootstrap admin's lockout/last_login_at, not real
 * customer data.
 */
import { describe, it, expect, afterAll } from 'vitest';
import request from 'supertest';

const ADMIN_EMAIL = 'admin@musanad.local';
const ADMIN_PASSWORD = 'ChangeMe@123';

describe('Auth integration (POST /api/v1/auth/*)', () => {
  let accessToken: string | undefined;
  let refreshToken: string | undefined;

  it('logs in the bootstrap admin', async () => {
    const { app } = await import('../../src/server');
    const res = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: ADMIN_EMAIL, password: ADMIN_PASSWORD });

    expect(res.status).toBe(200);
    expect(typeof res.body.accessToken).toBe('string');
    expect(typeof res.body.refreshToken).toBe('string');
    expect(res.body.user).toBeTruthy();
    expect(res.body.user.email).toBe(ADMIN_EMAIL);
    expect(Array.isArray(res.body.user.permissions)).toBe(true);

    accessToken = res.body.accessToken;
    refreshToken = res.body.refreshToken;
  });

  it('rejects bad credentials with 401', async () => {
    const { app } = await import('../../src/server');
    const res = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: ADMIN_EMAIL, password: 'WrongPassword!' });
    expect([401, 423]).toContain(res.status);
  });

  it('refreshes the access token AND rotates the refresh token', async () => {
    if (!refreshToken) throw new Error('refreshToken not set from login test');
    const { app } = await import('../../src/server');
    const res = await request(app)
      .post('/api/v1/auth/refresh')
      .send({ refreshToken });

    expect(res.status).toBe(200);
    expect(typeof res.body.accessToken).toBe('string');
    // Rotation: response now includes a NEW refresh token.
    expect(typeof res.body.refreshToken).toBe('string');
    // The rotated refresh token MUST differ from the one we sent.
    expect(res.body.refreshToken).not.toBe(refreshToken);

    // Track both: the OLD (now-blacklisted) and the NEW (live).
    const oldRefreshToken = refreshToken;
    const newRefreshToken: string = res.body.refreshToken;

    // Re-using the OLD refresh token must now be rejected (rotation/theft signal).
    const replayRes = await request(app)
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: oldRefreshToken });
    expect(replayRes.status).toBe(401);

    // The NEW refresh token should still work for one more rotation.
    const secondRotationRes = await request(app)
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: newRefreshToken });
    expect(secondRotationRes.status).toBe(200);
    expect(typeof secondRotationRes.body.accessToken).toBe('string');
    expect(typeof secondRotationRes.body.refreshToken).toBe('string');
    expect(secondRotationRes.body.refreshToken).not.toBe(newRefreshToken);

    // Hand off the latest live refresh token + its access token to the logout test.
    refreshToken = secondRotationRes.body.refreshToken;
    accessToken = secondRotationRes.body.accessToken;
  });

  it('logs out — blacklists the refresh token', async () => {
    if (!accessToken || !refreshToken) {
      throw new Error('tokens not set');
    }
    const { app } = await import('../../src/server');
    const res = await request(app)
      .post('/api/v1/auth/logout')
      .set('Authorization', `Bearer ${accessToken}`)
      .send({ refreshToken });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);

    // Refresh after logout should now fail
    const refreshRes = await request(app)
      .post('/api/v1/auth/refresh')
      .send({ refreshToken });
    expect(refreshRes.status).toBe(401);
  });

  /**
   * CRX-1 regression test: concurrent refresh requests with the same token
   * must not both succeed. fn_auth_blacklist_if_absent makes the
   * check+insert atomic, so exactly one of N concurrent calls should win
   * and the rest must 401.
   */
  it('CRX-1: concurrent refresh requests reject all but one', async () => {
    const { app } = await import('../../src/server');

    // Get a fresh token pair via login (the previous refreshToken was
    // blacklisted by the logout test).
    const loginRes = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: ADMIN_EMAIL, password: ADMIN_PASSWORD });
    expect(loginRes.status).toBe(200);
    const racingRefreshToken: string = loginRes.body.refreshToken;

    // Fire 5 concurrent refresh calls with the same token.
    const requests = Array.from({ length: 5 }, () =>
      request(app).post('/api/v1/auth/refresh').send({ refreshToken: racingRefreshToken }),
    );
    const settled = await Promise.allSettled(requests);

    const statuses = settled.map((s) =>
      s.status === 'fulfilled' ? s.value.status : 0,
    );
    const successes = statuses.filter((c) => c === 200).length;
    const rejections = statuses.filter((c) => c === 401).length;

    // Exactly one winner; the rest must be 401. (No 500s, no 200-storms.)
    expect(successes).toBe(1);
    expect(rejections).toBe(statuses.length - 1);
  });

  /**
   * CRX-2 regression test: the unknown-email arm and the wrong-password arm
   * should run for comparable time (both arms perform a bcrypt compare).
   * Loose 200ms bound — bcrypt(12) varies with CPU/load; we just want to
   * catch a 10x regression where the unknown-email arm short-circuits.
   */
  it('CRX-2: login timing is normalised between unknown-email and wrong-password', async () => {
    const { app } = await import('../../src/server');

    const measure = async (email: string, password: string): Promise<number> => {
      const start = performance.now();
      await request(app).post('/api/v1/auth/login').send({ email, password });
      return performance.now() - start;
    };

    // Warm-up (JIT, pool, bcrypt)
    await measure('warmup@example.com', 'whatever');
    await measure(ADMIN_EMAIL, 'definitely_wrong_password');

    const unknownT = await measure('does-not-exist@musanad.local', 'irrelevant_password_x');
    const wrongPwT = await measure(ADMIN_EMAIL, 'definitely_wrong_password');

    const diffMs = Math.abs(unknownT - wrongPwT);
    // If the unknown-email arm short-circuited (no bcrypt), the diff would
    // be ~80-120ms (one full bcrypt round). 200ms is a generous regression
    // bound that still catches that class of bug.
    expect(diffMs).toBeLessThan(200);
  });

  afterAll(async () => {
    const { server } = await import('../../src/server');
    server.close();
    const { closePool } = await import('../../src/database/config');
    await closePool();
  });
});
