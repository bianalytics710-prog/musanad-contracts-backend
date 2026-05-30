/**
 * CR-V — Integration tests: Admin Product Module Toggle endpoints.
 *
 * Routes tested:
 *   GET    /api/v1/admin/modules               → fn_product_module_list
 *   PATCH  /api/v1/admin/modules/:key          → fn_product_module_set
 *   PATCH  /api/v1/admin/bundles/:code         → fn_product_bundle_set
 *
 * All endpoints require settings.read / settings.write permission (platform_admin or Super Admin).
 * contract_drafter should receive 403.
 *
 * ACs:
 *   AC-V-AM-01: GET /admin/modules as Super Admin → 200 + array of modules with key/isEnabled
 *   AC-V-AM-02: GET /admin/modules as drafter → 403
 *   AC-V-AM-03: PATCH /admin/modules/clauses isEnabled:false → 200 + module toggled off
 *   AC-V-AM-04: PATCH /admin/modules/clauses isEnabled:true → 200 + module toggled back on
 *   AC-V-AM-05: PATCH /admin/modules/:key with invalid body → 422 (Zod validation)
 *   AC-V-AM-06: PATCH /admin/bundles/clm isEnabled:false → 200 + bulk toggle
 *   AC-V-AM-07: PATCH /admin/bundles/clm isEnabled:true → 200 + restore
 *   AC-V-AM-08: PATCH /admin/bundles/platform (is_core) → 403 / domain error
 *   AC-V-AM-09: drafter on PATCH /admin/modules/:key → 403
 *
 * testLevels: ["integration"]
 * Runs against TEST_DATABASE_URL (migrations 343..345 applied).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  loginAdmin,
  closeAdminPool,
  adminPool,
  type LoginResult,
} from '../helpers/m1a-helpers';
import { seedFixtureUsers, signFixtureToken } from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let platformAdminToken: string;
let drafterToken: string;

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;

  admin = await loginAdmin(app);
  await seedFixtureUsers();
  platformAdminToken = signFixtureToken('platform_admin1');
  drafterToken = signFixtureToken('drafter1');
}, 90_000);

afterAll(async () => {
  // Best-effort restore: ensure clauses module is on and clm bundle is fully on
  try {
    await request(app)
      .patch('/api/v1/admin/modules/clauses')
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isEnabled: true, reason: 'test cleanup' });
    await request(app)
      .patch('/api/v1/admin/bundles/clm')
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isEnabled: true, reason: 'test cleanup' });
  } catch { /* swallow */ }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 30_000);

// ─────────────────────────────────────────────────────────────────────────────
// GET /admin/modules
// ─────────────────────────────────────────────────────────────────────────────

describe('GET /api/v1/admin/modules', () => {
  const ROUTE = '/api/v1/admin/modules';

  it('AC-V-AM-01: Super Admin → 200 + {bundles, modules} structure', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${admin.accessToken}`);

    expect(res.status).toBe(200);
    const body = res.body as {
      success: boolean;
      data: { bundles: Array<Record<string, unknown>>; modules: Array<Record<string, unknown>> };
    };
    expect(body.success).toBe(true);
    expect(body.data).toBeTruthy();
    // fn_product_module_list returns { bundles: [...], modules: [...] }
    expect(Array.isArray(body.data.bundles)).toBe(true);
    expect(Array.isArray(body.data.modules)).toBe(true);
    expect(body.data.modules.length).toBeGreaterThan(0);
    const first = body.data.modules[0]!;
    expect(typeof first.key).toBe('string');
    expect(first.isEnabled !== undefined).toBe(true);
  });

  it('AC-V-AM-02: contract_drafter → 403', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${drafterToken}`);

    expect(res.status).toBe(403);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// PATCH /admin/modules/:key
// ─────────────────────────────────────────────────────────────────────────────

describe('PATCH /api/v1/admin/modules/:key', () => {
  it('AC-V-AM-03: toggle clauses OFF as Super Admin → 200', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/modules/clauses')
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isEnabled: false, reason: 'CR-V integration test — toggle off' });

    expect(res.status).toBe(200);
    const body = res.body as { success: boolean; data: unknown };
    expect(body.success).toBe(true);
  });

  it('AC-V-AM-04: toggle clauses ON → 200', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/modules/clauses')
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isEnabled: true, reason: 'CR-V integration test — restore' });

    expect(res.status).toBe(200);
    const body = res.body as { success: boolean };
    expect(body.success).toBe(true);
  });

  it('AC-V-AM-05: invalid body (missing isEnabled) → 400 (Zod validation)', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/modules/clauses')
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ reason: 'missing isEnabled field' });

    expect(res.status).toBe(400);
  });

  it('AC-V-AM-09: drafter on PATCH /admin/modules/:key → 403', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/modules/clauses')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ isEnabled: false });

    expect(res.status).toBe(403);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// PATCH /admin/bundles/:code
// ─────────────────────────────────────────────────────────────────────────────

describe('PATCH /api/v1/admin/bundles/:code', () => {
  it('AC-V-AM-06: toggle clm bundle OFF → 200', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/bundles/clm')
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isEnabled: false, reason: 'CR-V integration test — bundle off' });

    expect(res.status).toBe(200);
    const body = res.body as { success: boolean };
    expect(body.success).toBe(true);
  });

  it('AC-V-AM-07: restore clm bundle ON → 200', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/bundles/clm')
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isEnabled: true, reason: 'CR-V integration test — bundle restore' });

    expect(res.status).toBe(200);
    const body = res.body as { success: boolean };
    expect(body.success).toBe(true);
  });

  it('AC-V-AM-08: toggle platform bundle → domain error (is_core cannot be disabled)', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/bundles/platform')
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isEnabled: false, reason: 'should fail' });

    // fn_product_bundle_set raises 42501 for is_core bundles; controller maps this to 403 or 409
    expect([403, 409, 422]).toContain(res.status);
  });
});
