/**
 * Unit tests — regression for BE-PATCH-1 in src/database/client.ts.
 *
 * The bug: pg.Pool auto-stringifies plain JS objects bound to JSONB params,
 * but does NOT auto-stringify arrays — it tries to bind them as Postgres
 * array literals. For fn_payment_schedule_create_bulk(p_rows JSONB), passing
 * `body.rows` (an array of objects) failed at the type cast.
 *
 * The patch: in callFunction's `boundArgs` mapper, detect arrays-containing-
 * objects and pre-stringify them. Arrays of primitives (e.g. string[] for
 * fn_contract_set_tags(p_tags TEXT[])) are left untouched so pg can bind
 * them as native arrays.
 *
 * These tests mock pg.Pool to capture the exact argument vector handed to
 * client.query() and assert the serialiser produced the right wire shape.
 *
 * Three tests:
 *   1. Array of objects (e.g. payment-schedule rows) is stringified.
 *   2. Array of primitives (e.g. string[] for tags) is passed through.
 *   3. Plain objects are stringified (existing M0 behaviour preserved).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

// Capture queries and their bound args for inspection.
type CapturedCall = { sql: string; params?: unknown[] };
const calls: CapturedCall[] = [];

vi.mock('../../src/database/config', () => {
  const fakePool = {
    connect: vi.fn(async () => ({
      query: vi.fn(async (sql: string, params?: unknown[]) => {
        calls.push({ sql, params });
        if (sql === 'BEGIN' || sql === 'COMMIT' || sql === 'ROLLBACK') return { rows: [] };
        if (sql.startsWith('SELECT set_config')) return { rows: [] };
        // SELECT fn_X(...) — return a JSONB success payload.
        return { rows: [{ result: { ok: true } }] };
      }),
      release: vi.fn(),
    })),
    query: vi.fn(async () => ({ rows: [{ ok: 1 }] })),
  };
  return {
    pool: () => fakePool,
    closePool: async () => {},
  };
});

const importClient = async () => await import('../../src/database/client');

describe('callFunction — JSONB array-of-objects regression (BE-PATCH-1)', () => {
  beforeEach(() => {
    calls.length = 0;
    vi.clearAllMocks();
  });

  it('arrays of objects are pre-stringified to JSON (so pg binds them as JSONB, not as Postgres array literals)', async () => {
    const { db } = await importClient();
    const rows = [
      { milestoneLabelEn: 'A', amountAed: 100 },
      { milestoneLabelEn: 'B', amountAed: 200 },
    ];
    await db.callFunction('fn_payment_schedule_create_bulk', [1, rows, true, 1], { actorId: 1 });

    const fnCall = calls.find((c) => c.sql.startsWith('SELECT fn_'));
    expect(fnCall).toBeDefined();
    const params = fnCall!.params!;
    // arg[0] = contract id, arg[1] = rows (must be JSON STRING), arg[2] = bool, arg[3] = actorId.
    expect(typeof params[1]).toBe('string');
    const parsed = JSON.parse(params[1] as string);
    expect(Array.isArray(parsed)).toBe(true);
    expect(parsed.length).toBe(2);
    expect(parsed[0].milestoneLabelEn).toBe('A');
    expect(parsed[1].amountAed).toBe(200);
  });

  it('arrays of primitives (string[]) are passed through (so pg binds them as TEXT[] for fn_contract_set_tags)', async () => {
    const { db } = await importClient();
    const tags = ['alpha', 'beta', 'gamma'];
    await db.callFunction('fn_contract_set_tags', [1, tags, 1], { actorId: 1 });

    const fnCall = calls.find((c) => c.sql.startsWith('SELECT fn_'));
    expect(fnCall).toBeDefined();
    const params = fnCall!.params!;
    // arg[1] = tags MUST be the original array (not a JSON string).
    expect(Array.isArray(params[1])).toBe(true);
    expect(params[1]).toEqual(tags);
  });

  it('plain objects are stringified to JSON (preserves M0 behaviour for fn_user_create-style p_data params)', async () => {
    const { db } = await importClient();
    const userPayload = { email: 'x@y.com', firstName: 'X' };
    await db.callFunction('fn_user_create', [userPayload, 1], { actorId: 1 });

    const fnCall = calls.find((c) => c.sql.startsWith('SELECT fn_'));
    expect(fnCall).toBeDefined();
    const params = fnCall!.params!;
    expect(typeof params[0]).toBe('string');
    const parsed = JSON.parse(params[0] as string);
    expect(parsed.email).toBe('x@y.com');
    expect(parsed.firstName).toBe('X');
  });
});
