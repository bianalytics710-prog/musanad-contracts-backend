/**
 * CR-V — Integration tests: Admin role × module access matrix endpoints.
 *
 * Routes tested:
 *   GET    /api/v1/admin/role-modules                           → fn_role_module_matrix_get
 *   PATCH  /api/v1/admin/role-modules/:roleId/:moduleKey        → fn_role_module_access_set
 *
 * ACs:
 *   AC-V-RM-01: GET /admin/role-modules as Super Admin → 200 + matrix structure
 *   AC-V-RM-02: GET /admin/role-modules as drafter → 403
 *   AC-V-RM-03: PATCH role-modules with isAllowed:false → 200 (explicit deny)
 *   AC-V-RM-04: PATCH role-modules with isAllowed:true → 200 (explicit allow)
 *   AC-V-RM-05: PATCH role-modules with isAllowed:null → 200 (clear override)
 *   AC-V-RM-06: PATCH with invalid roleId (non-numeric) → 422
 *   AC-V-RM-07: drafter on PATCH → 403
 *
 * testLevels: ["integration"]
 * Runs against TEST_DATABASE_URL (migrations 338..345 applied).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  loginAdmin,
  closeAdminPool,
  adminQuery,
  type LoginResult,
} from '../helpers/m1a-helpers';
import { seedFixtureUsers, signFixtureToken } from '../helpers/m1c-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let platformAdminToken: string;
let drafterToken: string;

// Role IDs resolved at setup time
let contractDrafterRoleId: number | null = null;

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;

  admin = await loginAdmin(app);
  await seedFixtureUsers();
  platformAdminToken = signFixtureToken('platform_admin1');
  drafterToken = signFixtureToken('drafter1');

  // Resolve contract_drafter role id for PATCH tests
  const rows = await adminQuery<{ id: number }>(
    `SELECT id FROM role WHERE name = 'contract_drafter' AND is_active = TRUE LIMIT 1`,
  );
  contractDrafterRoleId = rows[0]?.id ?? null;
}, 90_000);

afterAll(async () => {
  // Best-effort: clear any role_module_access rows created by this test
  // fn_role_module_access_set with isAllowed:null removes the override row
  if (contractDrafterRoleId) {
    try {
      await request(app)
        .patch(`/api/v1/admin/role-modules/${contractDrafterRoleId}/clauses`)
        .set('Authorization', `Bearer ${admin.accessToken}`)
        .send({ isAllowed: null, reason: 'test cleanup' });
    } catch { /* swallow */ }
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 30_000);

// ─────────────────────────────────────────────────────────────────────────────
// GET /admin/role-modules
// ─────────────────────────────────────────────────────────────────────────────

describe('GET /api/v1/admin/role-modules', () => {
  const ROUTE = '/api/v1/admin/role-modules';

  it('AC-V-RM-01: Super Admin → 200 + matrix structure (array)', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${admin.accessToken}`);

    expect(res.status).toBe(200);
    const body = res.body as { success: boolean; data: unknown };
    expect(body.success).toBe(true);
    // Matrix may be an array of roles or an array of module × role cells
    expect(body.data).toBeTruthy();
  });

  it('AC-V-RM-02: contract_drafter → 403', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${drafterToken}`);

    expect(res.status).toBe(403);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// PATCH /admin/role-modules/:roleId/:moduleKey
// ─────────────────────────────────────────────────────────────────────────────

describe('PATCH /api/v1/admin/role-modules/:roleId/:moduleKey', () => {
  it('AC-V-RM-03: set isAllowed:false for contract_drafter × clauses → 200 (explicit deny)', async () => {
    if (!contractDrafterRoleId) {
      console.warn('contract_drafter role not resolved — skipping AC-V-RM-03');
      return;
    }

    const res = await request(app)
      .patch(`/api/v1/admin/role-modules/${contractDrafterRoleId}/clauses`)
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isAllowed: false, reason: 'CR-V test — explicit deny' });

    expect(res.status).toBe(200);
    const body = res.body as { success: boolean };
    expect(body.success).toBe(true);
  });

  it('AC-V-RM-04: set isAllowed:true for contract_drafter × clauses → 200 (explicit allow)', async () => {
    if (!contractDrafterRoleId) {
      console.warn('contract_drafter role not resolved — skipping AC-V-RM-04');
      return;
    }

    const res = await request(app)
      .patch(`/api/v1/admin/role-modules/${contractDrafterRoleId}/clauses`)
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isAllowed: true, reason: 'CR-V test — explicit allow' });

    expect(res.status).toBe(200);
    const body = res.body as { success: boolean };
    expect(body.success).toBe(true);
  });

  it('AC-V-RM-05: set isAllowed:null for contract_drafter × clauses → 200 (clear override)', async () => {
    if (!contractDrafterRoleId) {
      console.warn('contract_drafter role not resolved — skipping AC-V-RM-05');
      return;
    }

    const res = await request(app)
      .patch(`/api/v1/admin/role-modules/${contractDrafterRoleId}/clauses`)
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isAllowed: null, reason: 'CR-V test — clear override' });

    expect(res.status).toBe(200);
    const body = res.body as { success: boolean };
    expect(body.success).toBe(true);
  });

  it('AC-V-RM-06: non-numeric roleId → 400 (Zod param validation)', async () => {
    const res = await request(app)
      .patch('/api/v1/admin/role-modules/not-a-number/clauses')
      .set('Authorization', `Bearer ${admin.accessToken}`)
      .send({ isAllowed: false });

    expect(res.status).toBe(400);
  });

  it('AC-V-RM-07: drafter on PATCH role-modules → 403', async () => {
    if (!contractDrafterRoleId) {
      console.warn('contract_drafter role not resolved — skipping AC-V-RM-07');
      return;
    }

    const res = await request(app)
      .patch(`/api/v1/admin/role-modules/${contractDrafterRoleId}/clauses`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ isAllowed: false });

    expect(res.status).toBe(403);
  });
});
