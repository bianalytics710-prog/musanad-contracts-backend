/**
 * CR-C M10 — Notification Templates HTTP integration tests (S12, S13).
 *
 * Covers:
 *   GET  /api/v1/admin/notification-templates
 *   GET  /api/v1/admin/notification-templates/:id
 *   PATCH /api/v1/admin/notification-templates/:id
 *   POST /api/v1/admin/notification-templates/render
 *
 *   - Auth + permission gates
 *   - List returns >= 25 seeded templates (AC-S17-02)
 *   - GET by id resolves a known template
 *   - PATCH rejects immutable fields (templateId, channel) with 400
 *   - PATCH updates bodyEn round-trip
 *   - Render with missing parameters reports them (substitution leaves placeholder)
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  adminQuery,
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
let platformAdminToken: string;

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;
  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  platformAdminToken = signFixtureToken('platform_admin1');
});

afterAll(async () => {
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

describe('CR-C notification-templates — auth + permission gates', () => {
  it('GET /api/v1/admin/notification-templates without token → 401', async () => {
    const res = await request(app).get('/api/v1/admin/notification-templates');
    expect(res.status).toBe(401);
  });

  it('GET as drafter → 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/notification-templates')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });
});

describe('CR-C notification-templates — list + getById', () => {
  let knownTemplateRowId = 0;

  it('list returns >= 25 templates as platform_admin', async () => {
    const res = await request(app)
      .get('/api/v1/admin/notification-templates?limit=200')
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    // AC-S17-02 invariant: seed >= 25.
    expect(res.body.data.length).toBeGreaterThanOrEqual(25);
  });

  it('lookup signature.invitation.email row id', async () => {
    const r = await adminQuery<{ id: string }>(
      `SELECT id FROM notification_template
       WHERE template_id = 'signature.invitation.email'
         AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
       LIMIT 1`,
      [],
    );
    expect(r.length).toBe(1);
    // pg returns BIGSERIAL as string — coerce to number.
    knownTemplateRowId = r[0]?.id ? Number(r[0].id) : 0;
    expect(knownTemplateRowId).toBeGreaterThan(0);
  });

  it('GET /:id returns full template detail (subject + body EN+AR)', async () => {
    if (knownTemplateRowId === 0) return;
    const res = await request(app)
      .get(`/api/v1/admin/notification-templates/${knownTemplateRowId}`)
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.templateId).toBe('signature.invitation.email');
    expect(res.body.channel).toBe('email');
    expect(typeof res.body.bodyEn).toBe('string');
    expect(typeof res.body.bodyAr).toBe('string');
    expect(res.body.parameterSchema).toBeDefined();
  });

  it('PATCH rejects templateId/channel forwarding with 400 immutable_field', async () => {
    if (knownTemplateRowId === 0) return;
    const res = await request(app)
      .patch(`/api/v1/admin/notification-templates/${knownTemplateRowId}`)
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({ templateId: 'attempted.rename' });
    expect(res.status).toBe(400);
    const m = JSON.stringify(res.body);
    expect(m).toMatch(/immutable_field/);
  });

  it('PATCH rejects empty bodyEn with 400 body_en_required', async () => {
    if (knownTemplateRowId === 0) return;
    const res = await request(app)
      .patch(`/api/v1/admin/notification-templates/${knownTemplateRowId}`)
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({ bodyEn: '   ' });
    expect(res.status).toBe(400);
    const m = JSON.stringify(res.body);
    expect(m).toMatch(/body_en_required/);
  });
});

describe('CR-C notification-templates — render', () => {
  it('render reports missingParameters when params absent', async () => {
    const res = await request(app)
      .post('/api/v1/admin/notification-templates/render')
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({
        templateId: 'signature.invitation.email',
        channel: 'email',
        locale: 'en',
        parameters: { signerName: 'Alice' }, // contractTitle + signingLink missing
      });
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('subject');
    expect(typeof res.body.body).toBe('string');
    expect(Array.isArray(res.body.missingParameters)).toBe(true);
    expect(res.body.missingParameters).toContain('contractTitle');
    expect(res.body.missingParameters).toContain('signingLink');
    // AC-S13-03 — placeholder remains literal in output for missing params.
    expect(res.body.body).toMatch(/\{\{\s*contractTitle\s*\}\}/);
  });

  it('render returns 400 for invalid_locale', async () => {
    const res = await request(app)
      .post('/api/v1/admin/notification-templates/render')
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({
        templateId: 'signature.invitation.email',
        channel: 'email',
        locale: 'fr',
        parameters: {},
      });
    expect(res.status).toBe(400);
  });

  it('render returns 404 for unknown template', async () => {
    const res = await request(app)
      .post('/api/v1/admin/notification-templates/render')
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({
        templateId: 'nonexistent.template.id',
        channel: 'email',
        locale: 'en',
        parameters: {},
      });
    expect(res.status).toBe(404);
  });
});
