/**
 * UAE Pass state store — unit tests for CRX-3.
 *
 * Covers:
 *   - storeState + consumeState happy path
 *   - single-use semantics (second consume returns null)
 *   - TTL expiry returns null
 *   - missing state returns null
 */
import { afterEach, describe, expect, it } from 'vitest';
import {
  _resetStateStore,
  _stateStoreSize,
  consumeState,
  storeState,
} from '../../src/integrations/uae-pass/state-store';

describe('UAE Pass state-store (CRX-3)', () => {
  afterEach(() => _resetStateStore());

  it('stores then consumes a state once', () => {
    storeState('state-abc');
    const r = consumeState('state-abc');
    expect(r).not.toBeNull();
    expect(r!.createdAt).toBeGreaterThan(0);
  });

  it('returns null on second consume of the same state (single-use)', () => {
    storeState('state-xyz');
    const first = consumeState('state-xyz');
    const second = consumeState('state-xyz');
    expect(first).not.toBeNull();
    expect(second).toBeNull();
  });

  it('returns null when state is unknown', () => {
    expect(consumeState('never-stored')).toBeNull();
  });

  it('returns null when state has expired (ttlMs=0)', () => {
    storeState('state-expired', { ttlMs: 0 });
    // Sleep one tick so expiresAt <= Date.now() is true
    const r = consumeState('state-expired');
    expect(r).toBeNull();
  });

  it('attaches and returns optional userId', () => {
    storeState('state-with-uid', { userId: 42n });
    const r = consumeState('state-with-uid');
    expect(r?.userId).toBe(42n);
  });

  it('throws on empty state value', () => {
    expect(() => storeState('')).toThrow();
  });

  it('decrements size on consume', () => {
    storeState('a');
    storeState('b');
    expect(_stateStoreSize()).toBe(2);
    consumeState('a');
    expect(_stateStoreSize()).toBe(1);
  });
});
