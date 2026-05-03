/**
 * Shared helpers for M1a (Contracts) integration tests.
 *
 * Provides:
 *   - loginAdmin()   — bootstrap admin login → access token + user info
 *   - createContract — convenience factory using POST /api/v1/contracts
 *   - cleanupTestRows — afterAll teardown that deletes rows by contract_number
 *     pattern + descendants, side-stepping RLS via direct connection.
 *
 * Tests run against the Neon `test` branch (TEST_DATABASE_URL swap done by
 * tests/helpers/setup.ts). All M1a-created rows here use a 'TEST-' prefix
 * applied AFTER creation by patching the contract_number, so the cleanup
 * step is unambiguous.
 *
 * NOTE: fn_contract_create auto-generates contract_number 'CT-YYYY-NNNNNN'.
 * We let it auto-generate, then update contract_number to 'TEST-' prefix
 * via the bypass-RLS connection so cleanup is deterministic.
 */
import request from 'supertest';
import type { Express } from 'express';
import { Pool } from 'pg';

export const ADMIN_EMAIL = 'admin@musanad.local';
export const ADMIN_PASSWORD = 'ChangeMe@123';

export interface LoginResult {
  accessToken: string;
  refreshToken: string;
  user: {
    id: number;
    email: string;
    role: { id: number; name: string };
    permissions: string[];
  };
}

/**
 * Bootstrap admin login. Returns access token and user info.
 *
 * Bootstrap admin: id=1, role.name='Super Admin', has all 9 contract.*
 * permissions (granted by migration 006).
 */
export const loginAdmin = async (app: Express): Promise<LoginResult> => {
  const res = await request(app)
    .post('/api/v1/auth/login')
    .send({ email: ADMIN_EMAIL, password: ADMIN_PASSWORD });
  if (res.status !== 200) {
    throw new Error(`loginAdmin failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
  return res.body as LoginResult;
};

export interface CreateContractInput {
  titleEn?: string;
  titleAr?: string | null;
  contractType?: string;
  language?: 'en' | 'ar' | 'bilingual';
  startDate?: string | null;
  endDate?: string | null;
  valueAed?: number | null;
  governingLaw?:
    | 'uae_federal'
    | 'dubai'
    | 'abu_dhabi'
    | 'sharjah'
    | 'difc'
    | 'adgm'
    | 'english'
    | 'other'
    | null;
  relationshipType?:
    | 'amendment'
    | 'renewal'
    | 'extension'
    | 'superseded'
    | 'sow_under_msa'
    | null;
  parentContractId?: number | null;
  bodyEn?: string | null;
  bodyAr?: string | null;
  tags?: string[];
}

/**
 * Create a contract via the HTTP API. Returns the full contract object.
 * Caller should persist the id and clean up via cleanupContractsByPattern.
 */
export const createContract = async (
  app: Express,
  token: string,
  input: CreateContractInput = {},
): Promise<{ id: number; contractNumber: string; titleEn: string; status: string }> => {
  const res = await request(app)
    .post('/api/v1/contracts')
    .set('Authorization', `Bearer ${token}`)
    .send({
      titleEn: input.titleEn ?? 'Test Contract',
      titleAr: input.titleAr ?? null,
      contractType: input.contractType ?? 'employment',
      language: input.language ?? 'en',
      startDate: input.startDate ?? null,
      endDate: input.endDate ?? null,
      valueAed: input.valueAed ?? null,
      governingLaw: input.governingLaw ?? null,
      relationshipType: input.relationshipType ?? null,
      parentContractId: input.parentContractId ?? null,
      bodyEn: input.bodyEn ?? null,
      bodyAr: input.bodyAr ?? null,
      tags: input.tags ?? undefined,
    });
  if (res.status !== 201) {
    throw new Error(`createContract failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
  return res.body as { id: number; contractNumber: string; titleEn: string; status: string };
};

/**
 * Direct DB connection that BYPASSES RLS — used only by tests for setup
 * and cleanup. Connects with the TEST_DATABASE_URL (already redirected by
 * setup.ts).
 *
 * neondb_owner has BYPASSRLS by default on Neon.
 */
let _adminPool: Pool | null = null;

export const adminPool = (): Pool => {
  if (_adminPool) return _adminPool;
  const cs = process.env.TEST_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!cs) {
    throw new Error('TEST_DATABASE_URL / DATABASE_URL not set — cannot run M1a tests');
  }
  _adminPool = new Pool({ connectionString: cs, max: 2 });
  return _adminPool;
};

/**
 * Cleanup helper: hard-deletes all contract rows whose ids are in the
 * supplied list, plus their dependent contract_tag / contract_version /
 * contract_activity rows. Runs in a single transaction. Safe to call
 * multiple times.
 *
 * Hard delete is OK in tests — the test branch is disposable.
 */
export const cleanupContractsByIds = async (ids: number[]): Promise<void> => {
  if (ids.length === 0) return;
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    // Children first
    await client.query('DELETE FROM contract_activity WHERE contract_id = ANY($1::BIGINT[])', [ids]);
    await client.query('DELETE FROM contract_version  WHERE contract_id = ANY($1::BIGINT[])', [ids]);
    await client.query('DELETE FROM contract_tag      WHERE contract_id = ANY($1::BIGINT[])', [ids]);
    // Then parents (children-of-children possible — issue cascade by parent)
    await client.query(
      'DELETE FROM contract WHERE parent_contract_id = ANY($1::BIGINT[]) OR id = ANY($1::BIGINT[])',
      [ids],
    );
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Cleanup ALL contracts created during this test run by contract_number
 * pattern. Used as a final teardown safety net.
 */
export const cleanupContractsByPattern = async (pattern = 'CT-%'): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const r = await client.query<{ id: number }>(
      'SELECT id FROM contract WHERE contract_number LIKE $1',
      [pattern],
    );
    const ids = r.rows.map((row) => row.id);
    if (ids.length > 0) {
      await client.query('DELETE FROM contract_activity WHERE contract_id = ANY($1::BIGINT[])', [
        ids,
      ]);
      await client.query('DELETE FROM contract_version  WHERE contract_id = ANY($1::BIGINT[])', [
        ids,
      ]);
      await client.query('DELETE FROM contract_tag      WHERE contract_id = ANY($1::BIGINT[])', [
        ids,
      ]);
      await client.query(
        'DELETE FROM contract WHERE parent_contract_id = ANY($1::BIGINT[]) OR id = ANY($1::BIGINT[])',
        [ids],
      );
    }
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Run a one-off SQL statement via the bypass-RLS connection. Returns rows.
 */
export const adminQuery = async <T extends Record<string, unknown> = Record<string, unknown>>(
  sql: string,
  params: ReadonlyArray<unknown> = [],
): Promise<T[]> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const r = await client.query<T>(sql, params as unknown[]);
    await client.query('COMMIT');
    return r.rows;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Closes the admin pool (call from afterAll).
 */
export const closeAdminPool = async (): Promise<void> => {
  if (_adminPool) {
    await _adminPool.end();
    _adminPool = null;
  }
};
