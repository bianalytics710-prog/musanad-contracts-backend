/**
 * password.util — bcrypt hash / compare.
 */
import { describe, it, expect } from 'vitest';
import { hashPassword, comparePassword, PASSWORD_HASH_ROUNDS } from '../../src/utils/password.util';

describe('password.util', () => {
  it('uses bcrypt cost 12', () => {
    expect(PASSWORD_HASH_ROUNDS).toBe(12);
  });

  it('hashes and verifies a password', async () => {
    const hash = await hashPassword('Hunter2!');
    expect(hash.startsWith('$2')).toBe(true); // bcrypt prefix ($2a/$2b)
    expect(hash.length).toBeGreaterThan(50);

    expect(await comparePassword('Hunter2!', hash)).toBe(true);
    expect(await comparePassword('wrong', hash)).toBe(false);
  });

  it('returns false on empty inputs (does not throw)', async () => {
    expect(await comparePassword('', 'whatever')).toBe(false);
    expect(await comparePassword('plain', '')).toBe(false);
  });

  it('two hashes of the same plaintext differ (random salt)', async () => {
    const a = await hashPassword('Hunter2!');
    const b = await hashPassword('Hunter2!');
    expect(a).not.toBe(b);
    expect(await comparePassword('Hunter2!', a)).toBe(true);
    expect(await comparePassword('Hunter2!', b)).toBe(true);
  });
});
