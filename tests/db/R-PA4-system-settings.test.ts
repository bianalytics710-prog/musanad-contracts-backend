/**
 * R-PA4 — system_setting fns (migration 097).
 *
 * Covers fn_system_setting_list + fn_system_setting_set:
 *   * permission gate (drafter rejected on read AND write)
 *   * shape (10 default rows across 3 categories)
 *   * roundtrip (set → list reflects new value)
 *   * P0002 on unknown key
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';
import { adminQuery } from '../helpers/m1a-helpers';

let PLATFORM_ADMIN: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;

const ORIGINAL_VALUE_KEY = 'workspaceName';
let originalValue: unknown = null;

beforeAll(async () => {
  await seedFixtureUsers();
  PLATFORM_ADMIN = getFixture('platform_admin1');
  DRAFTER = getFixture('drafter1');

  const rows = await adminQuery<{ value: unknown }>(
    `SELECT value FROM system_setting WHERE key = $1`,
    [ORIGINAL_VALUE_KEY],
  );
  originalValue = rows[0]?.value ?? null;
});

afterAll(async () => {
  if (originalValue !== null) {
    await adminQuery(
      `UPDATE system_setting SET value = $1, updated_at = CURRENT_TIMESTAMP WHERE key = $2`,
      [JSON.stringify(originalValue), ORIGINAL_VALUE_KEY],
    );
  }
});

describe('R-PA4 — fn_system_setting_list', () => {
  it('platform_admin sees all 10 default settings', async () => {
    const r: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_system_setting_list',
      [],
    );
    expect(Array.isArray(r.settings)).toBe(true);
    expect(r.settings.length).toBeGreaterThanOrEqual(10);
    const cats = new Set(r.settings.map((s: any) => s.category));
    expect(cats.has('general')).toBe(true);
    expect(cats.has('uae_pass')).toBe(true);
    expect(cats.has('branding')).toBe(true);
  });

  it('rejects contract_drafter with 42501', async () => {
    await expect(
      callFnAs(DRAFTER.id, 'fn_system_setting_list', []),
    ).rejects.toThrow(/forbidden|42501/);
  });
});

describe('R-PA4 — fn_system_setting_set', () => {
  it('platform_admin can update workspaceName + list reflects it', async () => {
    const next = JSON.stringify('Musanad CLM (R-PA4 test)');
    const r: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_system_setting_set',
      [ORIGINAL_VALUE_KEY, next, PLATFORM_ADMIN.id],
    );
    expect(r.key).toBe(ORIGINAL_VALUE_KEY);

    const after: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_system_setting_list',
      [],
    );
    const row = after.settings.find((s: any) => s.key === ORIGINAL_VALUE_KEY);
    expect(row).toBeDefined();
    expect(row.value).toBe('Musanad CLM (R-PA4 test)');
  });

  it('rejects contract_drafter on write with 42501', async () => {
    await expect(
      callFnAs(
        DRAFTER.id,
        'fn_system_setting_set',
        [ORIGINAL_VALUE_KEY, JSON.stringify('hacked'), DRAFTER.id],
      ),
    ).rejects.toThrow(/forbidden|42501/);
  });

  it('rejects unknown key with P0002 / does-not-exist', async () => {
    await expect(
      callFnAs(
        PLATFORM_ADMIN.id,
        'fn_system_setting_set',
        ['nonExistentKey', JSON.stringify('x'), PLATFORM_ADMIN.id],
      ),
    ).rejects.toThrow(/does not exist|P0002/);
  });
});
