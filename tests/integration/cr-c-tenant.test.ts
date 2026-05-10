/**
 * CR-C M10 — Tenant list / get-by-id HTTP integration tests (S8).
 *
 * Covers:
 *   GET /api/v1/admin/tenants
 *   GET /api/v1/admin/tenants/:id
 *
 *   - 401 unauthenticated
 *   - 403 missing tenant.read
 *   - 200 list returns ADNOC + extended fields populated
 *   - 200 get-by-id resolves the seeded ADNOC UUID
 *   - 404 unknown UUID
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  closeAdminPool,
  loginAdmin,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  signFixtureToken,
} from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

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
  expect(getFixture('platform_admin1').roleName).toBe('platform_admin');
});

afterAll(async () => {
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

describe('CR-C tenant — auth + permission gates', () => {
  it('GET /api/v1/admin/tenants without token → 401', async () => {
    const res = await request(app).get('/api/v1/admin/tenants');
    expect(res.status).toBe(401);
  });

  it('GET /api/v1/admin/tenants as drafter → 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/tenants')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('GET /api/v1/admin/tenants as platform_admin → 200', async () => {
    const res = await request(app)
      .get('/api/v1/admin/tenants')
      .set('Authorization', `Bearer ${platformAdminToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('data');
    expect(res.body).toHaveProperty('pagination');
  });
});

describe('CR-C tenant — happy path', () => {
  it('list returns ADNOC seed row with extended fields', async () => {
    const res = await request(app)
      .get('/api/v1/admin/tenants')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    const data = res.body.data as Array<Record<string, unknown>>;
    expect(Array.isArray(data)).toBe(true);
    expect(data.length).toBeGreaterThanOrEqual(1);
    const adnoc = data.find((t) => t.id === ADNOC_TENANT_ID);
    expect(adnoc).toBeDefined();
    expect(adnoc?.name).toBe('ADNOC');
    expect(adnoc?.industry).toBe('oil_gas');
    expect(adnoc?.dataRegion).toBe('UAE');
    expect(adnoc?.riskAppetite).toBe('standard');
    expect(adnoc?.configPack).toBeDefined();
  });

  it('get-by-id resolves the ADNOC UUID', async () => {
    const res = await request(app)
      .get(`/api/v1/admin/tenants/${ADNOC_TENANT_ID}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(ADNOC_TENANT_ID);
    expect(res.body.name).toBe('ADNOC');
    expect(res.body.industry).toBe('oil_gas');
    expect(res.body.dataRegion).toBe('UAE');
    expect(res.body).toHaveProperty('updatedAt');
  });

  it('get-by-id returns 404 for unknown UUID', async () => {
    const res = await request(app)
      .get('/api/v1/admin/tenants/ffffffff-ffff-ffff-ffff-ffffffffffff')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
  });

  it('get-by-id returns 400 for malformed UUID', async () => {
    const res = await request(app)
      .get('/api/v1/admin/tenants/not-a-uuid')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(400);
  });
});
