/**
 * Unit tests for the M1a STRUCTURED_RAISE_RE translator branches in
 * src/database/client.ts.
 *
 * The translator pattern is:
 *   'fn_<name>: <field>:<message>'
 *
 * Routing rules (M1a additions):
 *   - field in {id, contractId}                 → 404 NOT_FOUND
 *   - field in {children, contractNumber, versionNumber} → 409 CONFLICT
 *   - any other field                           → 400 VALIDATION_ERROR
 *
 * We test these by mocking pg.Pool inside the module so callFunction()
 * surfaces the synthetic Postgres error and we can observe the ApiError
 * the translator produces.
 *
 * The pool is mocked at module scope using vi.mock so the import in
 * client.ts picks up the stub before any real connection attempt.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

// Synthetic PG error fabricator
const makePgError = (
  message: string,
  code?: string,
): Error & { code?: string } => {
  const err = new Error(message) as Error & { code?: string };
  if (code !== undefined) err.code = code;
  return err;
};

// Mock the pool() factory so that connect() returns a fake client whose
// query() throws on the SELECT fn_*(...) call.
const fakeClientFactory = (queryImpl: (sql: string, params?: unknown[]) => Promise<unknown>) => ({
  query: vi.fn(queryImpl),
  release: vi.fn(),
});

vi.mock('../../src/database/config', () => {
  const ctx: { nextQueryImpl: ((sql: string, params?: unknown[]) => Promise<unknown>) | null } = {
    nextQueryImpl: null,
  };
  const fakePool = {
    connect: vi.fn(async () => {
      const impl = ctx.nextQueryImpl ?? (async () => ({ rows: [] }));
      return fakeClientFactory(impl);
    }),
    query: vi.fn(async () => ({ rows: [{ ok: 1 }] })),
  };
  return {
    pool: () => fakePool,
    closePool: async () => {},
    // expose helper for tests
    __ctx: ctx,
  };
});

// Re-import after mocks are wired up
const importClient = async () => await import('../../src/database/client');
const importConfig = async () => await import('../../src/database/config');

describe('callFunction — STRUCTURED_RAISE_RE translator branches', () => {
  beforeEach(async () => {
    vi.clearAllMocks();
  });

  const setQueryImpl = async (
    impl: (sql: string, params?: unknown[]) => Promise<unknown>,
  ): Promise<void> => {
    const cfg = (await importConfig()) as unknown as {
      __ctx: { nextQueryImpl: typeof impl };
    };
    cfg.__ctx.nextQueryImpl = impl;
  };

  it('id field → 404 NOT_FOUND', async () => {
    const { db } = await importClient();
    await setQueryImpl(async (sql) => {
      if (sql === 'BEGIN') return { rows: [] };
      if (sql === 'COMMIT') return { rows: [] };
      if (sql === 'ROLLBACK') return { rows: [] };
      if (sql.startsWith('SELECT set_config')) return { rows: [] };
      if (sql.startsWith('SELECT fn_test_func')) {
        throw new Error('fn_test_func: id:Contract not found');
      }
      return { rows: [] };
    });
    try {
      await db.callFunction('fn_test_func', [1], { actorId: 1 });
      expect.fail('expected throw');
    } catch (err: unknown) {
      const e = err as { statusCode: number; code: string; fields?: Record<string, string> };
      expect(e.statusCode).toBe(404);
      expect(e.code).toBe('NOT_FOUND');
      expect(e.fields?.id).toBe('Contract not found');
    }
  });

  it('contractId field → 404 NOT_FOUND', async () => {
    const { db } = await importClient();
    await setQueryImpl(async (sql) => {
      if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(sql)) return { rows: [] };
      if (sql.startsWith('SELECT set_config')) return { rows: [] };
      if (sql.startsWith('SELECT fn_x')) {
        throw new Error('fn_x: contractId:Contract not found');
      }
      return { rows: [] };
    });
    try {
      await db.callFunction('fn_x', [1], { actorId: 1 });
      expect.fail('expected throw');
    } catch (err: unknown) {
      const e = err as { statusCode: number; code: string; fields?: Record<string, string> };
      expect(e.statusCode).toBe(404);
      expect(e.code).toBe('NOT_FOUND');
      expect(e.fields?.contractId).toBe('Contract not found');
    }
  });

  it('children field → 409 CONFLICT', async () => {
    const { db } = await importClient();
    await setQueryImpl(async (sql) => {
      if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(sql)) return { rows: [] };
      if (sql.startsWith('SELECT set_config')) return { rows: [] };
      if (sql.startsWith('SELECT fn_x')) {
        throw new Error('fn_x: children:Cannot delete contract with active child contracts');
      }
      return { rows: [] };
    });
    try {
      await db.callFunction('fn_x', [1], { actorId: 1 });
      expect.fail('expected throw');
    } catch (err: unknown) {
      const e = err as { statusCode: number; code: string; fields?: Record<string, string> };
      expect(e.statusCode).toBe(409);
      expect(e.code).toBe('CONFLICT');
      expect(e.fields?.children).toBe('Cannot delete contract with active child contracts');
    }
  });

  it('contractNumber field → 409 CONFLICT', async () => {
    const { db } = await importClient();
    await setQueryImpl(async (sql) => {
      if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(sql)) return { rows: [] };
      if (sql.startsWith('SELECT set_config')) return { rows: [] };
      if (sql.startsWith('SELECT fn_x')) {
        throw new Error('fn_x: contractNumber:Contract number already exists');
      }
      return { rows: [] };
    });
    try {
      await db.callFunction('fn_x', [1], { actorId: 1 });
      expect.fail('expected throw');
    } catch (err: unknown) {
      const e = err as { statusCode: number; code: string };
      expect(e.statusCode).toBe(409);
      expect(e.code).toBe('CONFLICT');
    }
  });

  it('versionNumber field → 409 CONFLICT', async () => {
    const { db } = await importClient();
    await setQueryImpl(async (sql) => {
      if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(sql)) return { rows: [] };
      if (sql.startsWith('SELECT set_config')) return { rows: [] };
      if (sql.startsWith('SELECT fn_x')) {
        throw new Error('fn_x: versionNumber:Version conflict — please retry');
      }
      return { rows: [] };
    });
    try {
      await db.callFunction('fn_x', [1], { actorId: 1 });
      expect.fail('expected throw');
    } catch (err: unknown) {
      const e = err as { statusCode: number; code: string };
      expect(e.statusCode).toBe(409);
      expect(e.code).toBe('CONFLICT');
    }
  });

  it('any other field name → 400 VALIDATION_ERROR with field detail', async () => {
    const { db } = await importClient();
    await setQueryImpl(async (sql) => {
      if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(sql)) return { rows: [] };
      if (sql.startsWith('SELECT set_config')) return { rows: [] };
      if (sql.startsWith('SELECT fn_x')) {
        throw new Error('fn_x: titleEn:Title (English) is required');
      }
      return { rows: [] };
    });
    try {
      await db.callFunction('fn_x', [1], { actorId: 1 });
      expect.fail('expected throw');
    } catch (err: unknown) {
      const e = err as { statusCode: number; code: string; fields?: Record<string, string> };
      expect(e.statusCode).toBe(400);
      expect(e.code).toBe('VALIDATION_ERROR');
      expect(e.fields?.titleEn).toBe('Title (English) is required');
    }
  });

  it('SQLSTATE 42501 (RLS denial) → 403 FORBIDDEN', async () => {
    const { db } = await importClient();
    await setQueryImpl(async (sql) => {
      if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(sql)) return { rows: [] };
      if (sql.startsWith('SELECT set_config')) return { rows: [] };
      if (sql.startsWith('SELECT fn_x')) {
        throw makePgError('row-level security policy denial', '42501');
      }
      return { rows: [] };
    });
    try {
      await db.callFunction('fn_x', [1], { actorId: 1 });
      expect.fail('expected throw');
    } catch (err: unknown) {
      const e = err as { statusCode: number; code: string };
      expect(e.statusCode).toBe(403);
      expect(e.code).toBe('FORBIDDEN');
    }
  });

  it('Invalid fnName → InternalError before connection', async () => {
    const { db } = await importClient();
    try {
      await db.callFunction('1bad-name; DROP TABLE users', [1]);
      expect.fail('expected throw');
    } catch (err: unknown) {
      const e = err as { statusCode: number };
      expect(e.statusCode).toBe(500);
    }
  });
});
