/**
 * M22 / CR-MIG-DRIVE — token-cipher.service.ts unit tests.
 *
 * Covers:
 *   - encrypt → decrypt round-trip preserves plaintext
 *   - distinct IVs per encryption (no deterministic output)
 *   - tampered ciphertext rejected with ValidationError
 *   - empty / non-string inputs rejected
 *
 * Requires TOKEN_CIPHER_KEY env var (set by .env.local in dev).
 */
import { describe, it, expect, beforeAll } from 'vitest';
import { encryptToken, decryptToken, _resetCipherKeyCacheForTesting } from '../../src/services/token-cipher.service';
import { validateEnv } from '../../src/utils/env-validation.util';

beforeAll(() => {
  // Make sure a key exists for tests — if not in env, fabricate one.
  if (!process.env.TOKEN_CIPHER_KEY) {
    const buf = Buffer.alloc(32);
    for (let i = 0; i < 32; i++) buf[i] = i + 1;
    process.env.TOKEN_CIPHER_KEY = buf.toString('base64');
  }
  validateEnv();
  _resetCipherKeyCacheForTesting();
});

describe('token-cipher.service', () => {
  it('round-trips a plaintext token', () => {
    const pt = 'ya29.a0AfH6SMC_fake_access_token_value';
    const enc = encryptToken(pt);
    const dec = decryptToken(enc);
    expect(dec).toBe(pt);
  });

  it('produces a different ciphertext each call (random IV)', () => {
    const pt = 'same-plaintext';
    const a = encryptToken(pt);
    const b = encryptToken(pt);
    expect(a).not.toBe(b);
    expect(decryptToken(a)).toBe(pt);
    expect(decryptToken(b)).toBe(pt);
  });

  it('rejects tampered ciphertext (auth-tag mismatch)', () => {
    const enc = encryptToken('hello');
    // Flip a byte deep in the ciphertext body
    const buf = Buffer.from(enc, 'base64');
    buf[buf.length - 1] ^= 0xff;
    const tampered = buf.toString('base64');
    expect(() => decryptToken(tampered)).toThrow();
  });

  it('rejects empty / non-string input', () => {
    expect(() => encryptToken('')).toThrow();
    // @ts-expect-error — runtime guard
    expect(() => encryptToken(null)).toThrow();
    expect(() => decryptToken('')).toThrow();
  });

  it('rejects too-short blob', () => {
    expect(() => decryptToken('Zm9v')).toThrow();
  });
});
