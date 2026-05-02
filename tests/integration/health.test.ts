/**
 * GET /api/health — integration test against Neon m0-foundation branch.
 *
 * If DATABASE_URL is unreachable from the test runner, this test will fail
 * with status 503 — that's the correct behavior. Surface clearly so the
 * runner knows to skip in offline environments.
 */
import { describe, it, expect, afterAll } from 'vitest';
import request from 'supertest';

describe('GET /api/health', () => {
  it('returns 200 ok when DB is reachable', async () => {
    const { app, server } = await import('../../src/server');

    const res = await request(app).get('/api/health');

    // We accept 200 (DB reachable) — fail loudly otherwise so the dev
    // sees the real cause rather than a silent skip.
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(res.body.db).toBe('reachable');
    expect(typeof res.body.uptime).toBe('number');
    expect(typeof res.body.timestamp).toBe('string');
    expect(res.headers['x-request-id']).toBeTruthy();

    // Close server so vitest doesn't hang
    server.close();
  });

  afterAll(async () => {
    // Belt + braces — ensure pool is closed
    const { closePool } = await import('../../src/database/config');
    await closePool();
  });
});
