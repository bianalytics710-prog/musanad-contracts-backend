/**
 * M22 / CR-MIG-DRIVE — AES-256-GCM cipher for OAuth tokens.
 *
 * Format on disk (base64-encoded, single string):
 *   12-byte IV || 16-byte auth-tag || ciphertext
 *
 * Key handling:
 *   - Dev: env var TOKEN_CIPHER_KEY (base64-encoded 32 bytes).
 *   - Production: rotate to KMS / Vault — fetch the data key on boot, never
 *     bake into the image. The interface below is key-source-agnostic; only
 *     getKey() needs to swap for the KMS path.
 *
 * Defence-in-depth:
 *   - IV is random per encryption (12 bytes from crypto.randomBytes).
 *   - AAD optional — currently unused (token rows already carry tenant + id
 *     to scope authn).
 *   - Decrypt throws ValidationError on auth-tag mismatch; never returns
 *     plaintext on tampering.
 */
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { env } from '../utils/env-validation.util';
import { InternalError, ValidationError } from '../utils/errors.util';

const ALGO = 'aes-256-gcm';
const KEY_LEN = 32;
const IV_LEN = 12;
const TAG_LEN = 16;

let cachedKey: Buffer | null = null;

function getKey(): Buffer {
  if (cachedKey) return cachedKey;
  const raw = env().TOKEN_CIPHER_KEY;
  if (!raw) {
    throw new InternalError(
      'TOKEN_CIPHER_KEY not set — M22 OAuth token storage requires a 32-byte base64 cipher key',
    );
  }
  let key: Buffer;
  try {
    key = Buffer.from(raw, 'base64');
  } catch {
    throw new InternalError('TOKEN_CIPHER_KEY is not valid base64');
  }
  if (key.length !== KEY_LEN) {
    throw new InternalError(
      `TOKEN_CIPHER_KEY must decode to exactly ${KEY_LEN} bytes — got ${key.length}`,
    );
  }
  cachedKey = key;
  return key;
}

/**
 * Encrypt a plaintext token (string). Returns the on-disk encoded form
 * (base64 of IV || tag || ciphertext). Safe to persist into a TEXT column.
 *
 * Empty / null input is rejected; callers should not invoke for empty
 * tokens (use NULL columns instead).
 */
export function encryptToken(plaintext: string): string {
  if (typeof plaintext !== 'string' || plaintext.length === 0) {
    throw new ValidationError('encryptToken: plaintext must be non-empty string');
  }
  const iv = randomBytes(IV_LEN);
  const cipher = createCipheriv(ALGO, getKey(), iv);
  const ct = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, ct]).toString('base64');
}

/**
 * Decrypt a previously-encrypted blob produced by encryptToken(). Throws
 * ValidationError on tampering / wrong key / corrupt input.
 */
export function decryptToken(blob: string): string {
  if (typeof blob !== 'string' || blob.length === 0) {
    throw new ValidationError('decryptToken: blob must be non-empty string');
  }
  let buf: Buffer;
  try {
    buf = Buffer.from(blob, 'base64');
  } catch {
    throw new ValidationError('decryptToken: blob is not valid base64');
  }
  if (buf.length < IV_LEN + TAG_LEN + 1) {
    throw new ValidationError('decryptToken: ciphertext too short');
  }
  const iv = buf.subarray(0, IV_LEN);
  const tag = buf.subarray(IV_LEN, IV_LEN + TAG_LEN);
  const ct = buf.subarray(IV_LEN + TAG_LEN);
  const decipher = createDecipheriv(ALGO, getKey(), iv);
  decipher.setAuthTag(tag);
  let pt: Buffer;
  try {
    pt = Buffer.concat([decipher.update(ct), decipher.final()]);
  } catch {
    throw new ValidationError('decryptToken: auth-tag verification failed');
  }
  return pt.toString('utf8');
}

/**
 * Test/dev helper — clears the cached key so a unit test can rotate the
 * env var between encrypt + decrypt and assert auth-tag verification.
 * Production code should never call this.
 */
export function _resetCipherKeyCacheForTesting(): void {
  cachedKey = null;
}
