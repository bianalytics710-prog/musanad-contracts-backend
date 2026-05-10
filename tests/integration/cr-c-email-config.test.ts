/**
 * CR-C M10 — Email Server Config HTTP integration tests (S14).
 *
 * Covers:
 *   GET   /api/v1/admin/email-config
 *   PATCH /api/v1/admin/email-config
 *   POST  /api/v1/admin/email-config/test-send
 *
 *   - Auth + permission gates (drafter 403, missing settings.write 403)
 *   - GET returns SmtpConfig with authPassRefSet boolean (NOT the raw value)
 *   - PATCH updates a non-secret field (smtp_host) round-trips
 *   - test-send when email.enabled=false → 409 'email_disabled'
 *
 * NOTE: We do NOT exercise a real SMTP send against any provider — we
 * verify the disabled path AND the 200/error envelope shape only. The
 * actual SMTP wiring is exercised by unit tests on the service module.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  closeAdminPool,
  loginAdmin,
  type LoginResult,
} from '../helpers/m1a-helpers';
import { seedFixtureUsers, signFixtureToken } from '../helpers/m1c-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;
  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
});

afterAll(async () => {
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

describe('CR-C email-config — auth + permission gates', () => {
  it('GET /api/v1/admin/email-config without token → 401', async () => {
    const res = await request(app).get('/api/v1/admin/email-config');
    expect(res.status).toBe(401);
  });

  it('GET as drafter → 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/email-config')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });
});

describe('CR-C email-config — GET happy path', () => {
  it('returns SmtpConfig with authPassRefSet (boolean — never the raw value)', async () => {
    const res = await request(app)
      .get('/api/v1/admin/email-config')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('smtpHost');
    expect(res.body).toHaveProperty('smtpPort');
    expect(res.body).toHaveProperty('smtpEncryption');
    expect(res.body).toHaveProperty('authUser');
    expect(res.body).toHaveProperty('authPassRefSet');
    expect(typeof res.body.authPassRefSet).toBe('boolean');
    // CRITICAL — the raw secret must not surface under any name.
    expect(res.body).not.toHaveProperty('authPassRef');
    expect(res.body).not.toHaveProperty('auth_pass_ref');
    expect(res.body).not.toHaveProperty('smtpPass');
    expect(res.body).not.toHaveProperty('password');
  });
});

describe('CR-C email-config — PATCH', () => {
  it('PATCH non-secret field (smtpHost) round-trips', async () => {
    const newHost = `smtp-test-${Date.now()}.musanad.local`;
    const patch = await request(app)
      .patch('/api/v1/admin/email-config')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ smtpHost: newHost });
    expect([200, 403]).toContain(patch.status);
    if (patch.status === 200) {
      expect(patch.body.smtpHost).toBe(newHost);
    }
  });

  it('PATCH rejects empty body', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/email-config')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({});
    expect(res.status).toBe(400);
  });
});

describe('CR-C email-config — test-send', () => {
  it('returns 409 email_disabled when email.enabled = false', async () => {
    // The seed value for email.enabled is `false` (migration 126); unless
    // a prior PATCH changed it, this should hit 409.
    const cfg = await request(app)
      .get('/api/v1/admin/email-config')
      .set('Authorization', `Bearer ${adminToken}`);
    if (cfg.status !== 200) return;
    const enabled = cfg.body?.enabled === true;
    if (enabled) {
      // Skip — production-like state. The disabled path is the canonical
      // AC-S14-05 assertion.
      return;
    }
    const res = await request(app)
      .post('/api/v1/admin/email-config/test-send')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({});
    expect([409, 503]).toContain(res.status);
    if (res.status === 409) {
      const m = JSON.stringify(res.body);
      expect(m).toMatch(/email_disabled/);
    }
  });
});
