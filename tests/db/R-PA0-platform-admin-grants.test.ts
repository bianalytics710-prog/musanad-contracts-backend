/**
 * R-PA0 — regression coverage for migration 094.
 *
 * Closes Platform Admin parity audit C1 — the platform_admin role lacked the
 * three permissions necessary to operate /app/admin/users + /app/admin/audit:
 *   - user.read.all
 *   - user.manage
 *   - audit.read
 *
 * Asserts:
 *   1. The three grants are present on platform_admin (migration 094 applied).
 *   2. fn_user_list invoked AS the platform_admin fixture returns rows.
 *
 * NOTE: fn_user_list is NOT itself permission-gated at the DB layer — the
 * 'user.read.all' authorise() check sits at the Express route. So this test
 * focuses on the role/permission seed + the fn_ result shape; per-route
 * 401/403 enforcement is covered by the integration tests.
 */
import { describe, it, expect, beforeAll } from 'vitest';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';
import { adminQuery } from '../helpers/m1a-helpers';

let PLATFORM_ADMIN: SeededFixtureUser;

beforeAll(async () => {
  await seedFixtureUsers();
  PLATFORM_ADMIN = getFixture('platform_admin1');
});

describe('R-PA0 — platform_admin role grants (migration 094)', () => {
  it('platform_admin role has user.read.all + user.manage + audit.read', async () => {
    const rows = await adminQuery<{ code: string }>(
      `SELECT p.code
         FROM role r
         JOIN role_permission rp
              ON rp.role_id = r.id AND rp.is_active = TRUE
         JOIN permission p
              ON p.id = rp.permission_id
        WHERE r.name = 'platform_admin'
          AND p.code IN ('user.read.all', 'user.manage', 'audit.read')
        ORDER BY p.code`,
      [],
    );
    const codes = rows.map((row) => row.code);
    expect(codes).toEqual(['audit.read', 'user.manage', 'user.read.all']);
  });
});

describe('R-PA0 — fn_user_list', () => {
  it('platform_admin invocation returns a paged response', async () => {
    const result: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_user_list',
      [1, 20, null, null],
    );
    expect(result).toBeDefined();
    expect(Array.isArray(result.data)).toBe(true);
    expect(result.pagination).toBeDefined();
    expect(typeof result.pagination.total).toBe('number');
    expect(result.pagination.total).toBeGreaterThan(0);
  });
});
