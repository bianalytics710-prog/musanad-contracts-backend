/**
 * R-PA2 — admin user row-action fns (migration 096).
 *
 * Covers:
 *   * fn_user_update — isActive support + self-suspend protection
 *   * fn_user_password_reset — happy path + self-reset block
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
let TARGET: SeededFixtureUser; // we suspend this user — restore in afterAll

beforeAll(async () => {
  await seedFixtureUsers();
  PLATFORM_ADMIN = getFixture('platform_admin1');
  TARGET = getFixture('drafter1');
});

afterAll(async () => {
  await adminQuery(
    `UPDATE "user" SET is_active = TRUE, updated_at = CURRENT_TIMESTAMP WHERE id = $1`,
    [TARGET.id],
  );
});

describe('R-PA2 — fn_user_update isActive', () => {
  it('admin can suspend a user', async () => {
    const r: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_user_update',
      [TARGET.id, { isActive: false }, PLATFORM_ADMIN.id],
    );
    expect(r).toBeDefined();
    expect(r.isActive).toBe(false);
  });

  it('admin can reactivate a suspended user', async () => {
    const r: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_user_update',
      [TARGET.id, { isActive: true }, PLATFORM_ADMIN.id],
    );
    expect(r).toBeDefined();
    expect(r.isActive).toBe(true);
  });

  it('rejects self-suspend with cannot-suspend-own-account', async () => {
    await expect(
      callFnAs(
        PLATFORM_ADMIN.id,
        'fn_user_update',
        [PLATFORM_ADMIN.id, { isActive: false }, PLATFORM_ADMIN.id],
      ),
    ).rejects.toThrow(/cannot suspend your own account/);
  });
});

describe('R-PA2 — fn_user_password_reset', () => {
  it('admin can reset another user password', async () => {
    const r: any = await callFnAs(
      PLATFORM_ADMIN.id,
      'fn_user_password_reset',
      [TARGET.id, '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS', PLATFORM_ADMIN.id],
    );
    expect(r.success).toBe(true);
    expect(Number(r.userId)).toBe(TARGET.id);
  });

  it('rejects self-reset with use-/auth/change-password message', async () => {
    await expect(
      callFnAs(
        PLATFORM_ADMIN.id,
        'fn_user_password_reset',
        [PLATFORM_ADMIN.id, '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS', PLATFORM_ADMIN.id],
      ),
    ).rejects.toThrow(/cannot reset your own password/);
  });

  it('rejects empty password hash', async () => {
    await expect(
      callFnAs(
        PLATFORM_ADMIN.id,
        'fn_user_password_reset',
        [TARGET.id, '', PLATFORM_ADMIN.id],
      ),
    ).rejects.toThrow(/passwordHash is required/);
  });
});
