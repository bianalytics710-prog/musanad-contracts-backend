/**
 * UAE Pass state store (CRX-3).
 *
 * Stores the OAuth/OIDC `state` value generated at /uae-pass/initiate so the
 * /uae-pass/callback handler can verify the state on return. This closes the
 * CSRF / login-substitution gap Codex flagged: previously state was generated
 * server-side and returned to the client but never matched on callback.
 *
 * IMPLEMENTATION NOTES
 * --------------------
 *  - In-memory Map keyed by state (random hex). TTL = 5 min. Lazy eviction
 *    on read PLUS a background sweeper running every 60s.
 *  - Single-use semantics: `consumeState` returns the record AND deletes it.
 *    A second callback with the same state will see `null` and the controller
 *    must reject.
 *  - This is acceptable for the mock UAE Pass provider in dev. Production
 *    requires a durable store (DB-backed `uae_pass_state` table or Redis)
 *    so state survives process restart and works across replicas. See
 *    src/integrations/uae-pass/live.provider.ts integration checklist §3.
 *
 * EXPORTED API
 * ------------
 *   storeState(state, opts?)   — register a state with optional userId + ttl
 *   consumeState(state)        — return + delete; null if absent or expired
 *   _resetStateStore()         — test-only; clears the map and stops the sweeper
 */

interface StateRecord {
  userId?: bigint;
  createdAt: number;
  expiresAt: number;
}

const DEFAULT_TTL_MS = 5 * 60 * 1000; // 5 min — UAE Pass spec recommendation
const SWEEP_INTERVAL_MS = 60 * 1000; // 60s — bounds memory in burst conditions

const _store = new Map<string, StateRecord>();
let _sweeper: NodeJS.Timeout | null = null;

const sweep = (): void => {
  const now = Date.now();
  for (const [k, v] of _store) {
    if (v.expiresAt <= now) _store.delete(k);
  }
};

const ensureSweeper = (): void => {
  if (_sweeper) return;
  _sweeper = setInterval(sweep, SWEEP_INTERVAL_MS);
  // Don't keep the event loop alive just for the sweeper.
  if (typeof _sweeper.unref === 'function') _sweeper.unref();
};

export interface StoreStateOptions {
  userId?: bigint;
  ttlMs?: number;
}

/**
 * Persist a UAE Pass state value with a TTL. Overwrites any existing entry
 * with the same state (rare; states are 32+ random hex chars).
 */
export const storeState = (state: string, opts: StoreStateOptions = {}): void => {
  if (!state || state.length === 0) {
    throw new Error('storeState: state is required');
  }
  ensureSweeper();
  const ttlMs = opts.ttlMs ?? DEFAULT_TTL_MS;
  const now = Date.now();
  const record: StateRecord = {
    createdAt: now,
    expiresAt: now + ttlMs,
  };
  if (opts.userId !== undefined) record.userId = opts.userId;
  _store.set(state, record);
};

/**
 * Look up + delete (single-use) a state value. Returns null if missing
 * or expired.
 */
export const consumeState = (
  state: string,
): { userId?: bigint; createdAt: number } | null => {
  if (!state) return null;
  const record = _store.get(state);
  if (!record) return null;
  // Always delete — single-use even on expiry path
  _store.delete(state);
  if (record.expiresAt <= Date.now()) {
    return null; // expired
  }
  const result: { userId?: bigint; createdAt: number } = { createdAt: record.createdAt };
  if (record.userId !== undefined) result.userId = record.userId;
  return result;
};

/** Test-only: clear store + stop sweeper so unit tests don't leak handles. */
export const _resetStateStore = (): void => {
  _store.clear();
  if (_sweeper) {
    clearInterval(_sweeper);
    _sweeper = null;
  }
};

/** Test-only: peek at store size (for assertions). */
export const _stateStoreSize = (): number => _store.size;
