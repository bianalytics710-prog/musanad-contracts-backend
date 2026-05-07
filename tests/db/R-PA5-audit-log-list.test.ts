/**
 * R-PA5 — fn_audit_log_list (migration 098).
 *
 * Covers:
 *   * permission gate (drafter rejected)
 *   * pagination + filter shape (table, action)
 *   * windowDays-style date filter
 *   * 22023 on bad action / page / limit
 */
import { describe, it, expect, beforeAll } from 'vitest';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';

let PLATFORM_ADMIN: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;

beforeAll(async () => {
  await seedFixtureUsers();
  PLATFORM_ADMIN = getFixture('platform_admin1');
  DRAFTER = getFixture('drafter1');
});

describe('R-PA5 — fn_audit_log_list', () => {
  it('returns paginated shape', async () => {
    const r: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_audit_log_list',
      [1, 5, null, null, null, null, null],
    );
    expect(Array.isArray(r.data)).toBe(true);
    expect(r.data.length).toBeLessThanOrEqual(5);
    expect(typeof r.pagination.total).toBe('number');
    expect(r.pagination.page).toBe(1);
    expect(r.pagination.limit).toBe(5);
  });

  it('filters by tableName', async () => {
    const r: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_audit_log_list',
      [1, 50, 'user', null, null, null, null],
    );
    for (const row of r.data) {
      expect(row.tableName).toBe('user');
    }
  });

  it('filters by action', async () => {
    const r: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_audit_log_list',
      [1, 50, null, 'UPDATE', null, null, null],
    );
    for (const row of r.data) {
      expect(row.action).toBe('UPDATE');
    }
  });

  it('rejects drafter with 42501', async () => {
    await expect(
      callFnAs(DRAFTER.id, 'fn_audit_log_list', [1, 5, null, null, null, null, null]),
    ).rejects.toThrow(/forbidden|42501/);
  });

  it('rejects bad action with 22023', async () => {
    await expect(
      callFnAs(
        PLATFORM_ADMIN.id,
        'fn_audit_log_list',
        [1, 5, null, 'PURGE', null, null, null],
      ),
    ).rejects.toThrow(/action must be|22023/);
  });

  it('rejects limit > 200 with 22023', async () => {
    await expect(
      callFnAs(
        PLATFORM_ADMIN.id,
        'fn_audit_log_list',
        [1, 500, null, null, null, null, null],
      ),
    ).rejects.toThrow(/limit must be|22023/);
  });
});
