/**
 * bcrypt hashing helpers. Cost factor = 12 (matches the seeded bootstrap
 * admin hash and CLAUDE.md §8 baseline).
 */
import bcrypt from 'bcryptjs';

const BCRYPT_ROUNDS = 12;

/**
 * Hash a plaintext password with bcrypt(12).
 * @returns the encoded hash string, e.g. `$2b$12$...`
 */
export const hashPassword = async (plain: string): Promise<string> => {
  if (!plain || plain.length === 0) {
    throw new Error('hashPassword: plain password is required');
  }
  return bcrypt.hash(plain, BCRYPT_ROUNDS);
};

/**
 * Compare a plaintext password against a stored bcrypt hash.
 * Returns false on any error rather than throwing — callers
 * always treat false as "auth failed".
 */
export const comparePassword = async (plain: string, hash: string): Promise<boolean> => {
  if (!plain || !hash) return false;
  try {
    return await bcrypt.compare(plain, hash);
  } catch {
    return false;
  }
};

export const PASSWORD_HASH_ROUNDS = BCRYPT_ROUNDS;
