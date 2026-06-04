/**
 * M22 / CR-MIG-DRIVE — DB function tests (focused targeted suite).
 *
 * Covers the security-critical bits of the migration topology:
 *   1. fn_migration_purge_all — permission gating + scope guard + dry-run shape
 *   2. fn_migration_record_check_duplicates — Level 1 (file-id) + Level 2 (sha)
 *   3. fn_external_connection_disconnect — tokens overwritten with NULL
 *   4. fn_migration_batch_rollback — soft-marks contracts + idempotency
 *   5. S2-21 — no PUBLIC EXECUTE on M22 fn_s
 *   6. AC-23 — native (non-migration) contracts survive the purge
 *
 * Runs against TEST_DATABASE_URL (migrations 466..471 applied).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, adminQuery, closeAdminPool } from '../helpers/m1a-helpers';
import { seedFixtureUsers, type SeededFixtureUser } from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const RUN = `crmig-${Date.now()}`;

let PLATFORM_ADMIN: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;

// Cleanup trackers
const trackedConnIds: number[] = [];
const trackedBatchIds: number[] = [];
const trackedContractIds: number[] = [];

async function callFn<T>(
  actorId: number,
  fnName: string,
  args: ReadonlyArray<unknown>,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<T> {
  if (!/^[a-z_][a-z0-9_]*$/i.test(fnName)) throw new Error(`bad fn name: ${fnName}`);
  const placeholders = args.map((_, i) => `$${i + 1}`).join(', ');
  const sql = `SELECT ${fnName}(${placeholders}) AS result`;
  const bound = args.map((v) => {
    if (v === undefined || v === null) return null;
    if (Array.isArray(v)) return v;
    if (typeof v === 'object' && !(v instanceof Date)) return JSON.stringify(v);
    return v;
  });
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const r = await client.query(sql, bound);
    await client.query('COMMIT');
    return r.rows[0].result as T;
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
}

async function createConnection(actorId: number): Promise<number> {
  const id = await callFn<number>(actorId, 'fn_external_connection_create', [
    'google_drive',
    `Drive ${RUN}`,
    `folder-${RUN}`,
    'Test folder',
    'enc-access',
    'enc-refresh',
    new Date(Date.now() + 3600_000),
    ['https://www.googleapis.com/auth/drive.readonly'],
    actorId,
  ]);
  trackedConnIds.push(id);
  return id;
}

async function createBatch(connId: number, actorId: number): Promise<number> {
  const id = await callFn<number>(actorId, 'fn_migration_batch_create', [
    connId, actorId, 'manual',
  ]);
  trackedBatchIds.push(id);
  return id;
}

beforeAll(async () => {
  const users = await seedFixtureUsers();
  PLATFORM_ADMIN = users.get('platform_admin1')!;
  DRAFTER = users.get('drafter1')!;
}, 60_000);

afterAll(async () => {
  // Best-effort cleanup
  if (trackedBatchIds.length > 0) {
    await adminQuery(
      `DELETE FROM migration_record WHERE migration_batch_id = ANY($1::bigint[])`,
      [trackedBatchIds],
    );
    await adminQuery(`DELETE FROM migration_batch WHERE id = ANY($1::bigint[])`, [trackedBatchIds]);
  }
  if (trackedConnIds.length > 0) {
    await adminQuery(`DELETE FROM external_connection WHERE id = ANY($1::bigint[])`, [trackedConnIds]);
  }
  if (trackedContractIds.length > 0) {
    await adminQuery(`DELETE FROM contract WHERE id = ANY($1::bigint[])`, [trackedContractIds]);
  }
  await closeAdminPool();
}, 30_000);

// ────────────────────────────────────────────────────────────────────────────
// 1. fn_external_connection_create / disconnect
// ────────────────────────────────────────────────────────────────────────────

describe('M22 — external_connection', () => {
  it('creates a connection and surfaces it via fn_external_connection_list (sanitized)', async () => {
    const id = await createConnection(PLATFORM_ADMIN.id);
    expect(Number(id)).toBeGreaterThan(0);
    const list = await callFn<Array<{ id: number; oauthAccessTokenEncrypted?: string }>>(
      PLATFORM_ADMIN.id,
      'fn_external_connection_list',
      [],
    );
    const row = list.find((r) => Number(r.id) === Number(id));
    expect(row).toBeDefined();
    // sanitized list MUST NOT include token blobs
    expect(row?.oauthAccessTokenEncrypted).toBeUndefined();
  });

  it('disconnect nulls out the token blobs', async () => {
    const id = await createConnection(PLATFORM_ADMIN.id);
    await callFn(PLATFORM_ADMIN.id, 'fn_external_connection_disconnect', [id, PLATFORM_ADMIN.id]);
    const r = await adminQuery<{ oauth_access_token_encrypted: string | null; status: string }>(
      `SELECT oauth_access_token_encrypted, status FROM external_connection WHERE id = $1`,
      [id],
    );
    expect(r[0].oauth_access_token_encrypted).toBeNull();
    expect(r[0].status).toBe('disconnected');
  });

  it('drafter cannot create/disconnect (permission gate)', async () => {
    await expect(
      callFn(DRAFTER.id, 'fn_external_connection_create', [
        'google_drive', 'x', `x-${RUN}`, 'x', 'a', 'b',
        new Date(Date.now() + 1000), ['x'], DRAFTER.id,
      ]),
    ).rejects.toThrow(/permission_denied/i);
  });
});

// ────────────────────────────────────────────────────────────────────────────
// 2. Duplicate detection (Level 1 + Level 2)
// ────────────────────────────────────────────────────────────────────────────

describe('M22 — duplicate detection', () => {
  it('returns id_match for same source_file_id on same connection', async () => {
    const conn = await createConnection(PLATFORM_ADMIN.id);
    const batch = await createBatch(conn, PLATFORM_ADMIN.id);
    // Manually insert a record in 'imported' state
    const sha = 'a'.repeat(64);
    const insRes = await adminQuery<{ id: number }>(
      `INSERT INTO migration_record (
         tenant_id, migration_batch_id, external_connection_id_of_batch,
         source_file_id, source_file_sha256, status
       ) VALUES ($1::uuid, $2, $3, $4, $5, 'imported') RETURNING id`,
      [ADNOC_TENANT_ID, batch, conn, `file-${RUN}`, sha],
    );
    const existingId = insRes[0].id;

    const r = await callFn<{ duplicateKind: string; duplicateOfRecordId: number | null }>(
      PLATFORM_ADMIN.id,
      'fn_migration_record_check_duplicates',
      [conn, `file-${RUN}`, null],
    );
    expect(r.duplicateKind).toBe('id_match');
    expect(Number(r.duplicateOfRecordId)).toBe(Number(existingId));
  });

  it('returns hash_match when file-id differs but sha matches', async () => {
    const conn = await createConnection(PLATFORM_ADMIN.id);
    const batch = await createBatch(conn, PLATFORM_ADMIN.id);
    const sha = 'b'.repeat(64);
    const insRes = await adminQuery<{ id: number }>(
      `INSERT INTO migration_record (
         tenant_id, migration_batch_id, external_connection_id_of_batch,
         source_file_id, source_file_sha256, status
       ) VALUES ($1::uuid, $2, $3, $4, $5, 'imported') RETURNING id`,
      [ADNOC_TENANT_ID, batch, conn, `orig-${RUN}`, sha],
    );
    const orig = insRes[0].id;
    const r = await callFn<{ duplicateKind: string; duplicateOfRecordId: number | null }>(
      PLATFORM_ADMIN.id,
      'fn_migration_record_check_duplicates',
      [conn, `copy-${RUN}`, sha],
    );
    expect(r.duplicateKind).toBe('hash_match');
    expect(Number(r.duplicateOfRecordId)).toBe(Number(orig));
  });

  it('returns none when no prior record matches', async () => {
    const conn = await createConnection(PLATFORM_ADMIN.id);
    const r = await callFn<{ duplicateKind: string }>(
      PLATFORM_ADMIN.id,
      'fn_migration_record_check_duplicates',
      [conn, `unseen-${RUN}`, 'c'.repeat(64)],
    );
    expect(r.duplicateKind).toBe('none');
  });
});

// ────────────────────────────────────────────────────────────────────────────
// 3. Batch rollback
// ────────────────────────────────────────────────────────────────────────────

describe('M22 — batch rollback', () => {
  it('soft-marks tagged contracts inactive + flips batch status', async () => {
    const conn = await createConnection(PLATFORM_ADMIN.id);
    const batch = await createBatch(conn, PLATFORM_ADMIN.id);

    // Create + tag two contracts
    const cIds: number[] = [];
    for (const n of [1, 2]) {
      const r = await adminQuery<{ id: number }>(
        `INSERT INTO contract (contract_number, title_en, contract_type, language, status,
                                migration_batch_id, created_by, updated_by, is_active, data_classification)
          VALUES ($1, $2, 'services', 'en', 'draft', $3, $4, $4, TRUE, 'demo') RETURNING id`,
        [`MIG-${RUN}-${n}`, `Test ${RUN}-${n}`, batch, PLATFORM_ADMIN.id],
      );
      cIds.push(r[0].id);
      trackedContractIds.push(r[0].id);
    }

    // Force batch to 'completed' so rollback is allowed
    await adminQuery(`UPDATE migration_batch SET status = 'completed' WHERE id = $1`, [batch]);

    const result = await callFn<{ contractsRolledBack: number; batchId: number }>(
      PLATFORM_ADMIN.id,
      'fn_migration_batch_rollback',
      [batch, PLATFORM_ADMIN.id, 'unit-test reason'],
    );
    expect(result.contractsRolledBack).toBe(2);

    const r = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count FROM contract WHERE id = ANY($1::bigint[]) AND is_active = FALSE`,
      [cIds],
    );
    expect(parseInt(r[0].count)).toBe(2);

    const b = await adminQuery<{ status: string; rolled_back_at: Date | null }>(
      `SELECT status, rolled_back_at FROM migration_batch WHERE id = $1`,
      [batch],
    );
    expect(b[0].status).toBe('rolled_back');
    expect(b[0].rolled_back_at).not.toBeNull();
  });

  it('rejects rollback when batch is in non-terminal state', async () => {
    const conn = await createConnection(PLATFORM_ADMIN.id);
    const batch = await createBatch(conn, PLATFORM_ADMIN.id);
    // Default status is 'queued' — non-terminal
    await expect(
      callFn(PLATFORM_ADMIN.id, 'fn_migration_batch_rollback', [batch, PLATFORM_ADMIN.id, 'x']),
    ).rejects.toThrow(/cannot rollback/i);
  });

  it('drafter cannot rollback (permission gate)', async () => {
    const conn = await createConnection(PLATFORM_ADMIN.id);
    const batch = await createBatch(conn, PLATFORM_ADMIN.id);
    await adminQuery(`UPDATE migration_batch SET status = 'completed' WHERE id = $1`, [batch]);
    await expect(
      callFn(DRAFTER.id, 'fn_migration_batch_rollback', [batch, DRAFTER.id, 'x']),
    ).rejects.toThrow(/permission_denied/i);
  });
});

// ────────────────────────────────────────────────────────────────────────────
// 4. fn_migration_purge_all — dry-run + scope guard
// ────────────────────────────────────────────────────────────────────────────

describe('M22 — purge_all', () => {
  it('dry-run returns counts without deleting', async () => {
    const result = await callFn<{ dryRun: boolean; counts: Record<string, number>; totalRows: number }>(
      PLATFORM_ADMIN.id,
      'fn_migration_purge_all',
      [true],
    );
    expect(result.dryRun).toBe(true);
    expect(typeof result.counts.migrationBatch).toBe('number');
    expect(typeof result.totalRows).toBe('number');
  });

  it('drafter cannot call (permission gate)', async () => {
    await expect(
      callFn(DRAFTER.id, 'fn_migration_purge_all', [true]),
    ).rejects.toThrow(/migration_purge_permission_required/i);
  });

  it('SCOPE GUARD — native (non-migration) contracts survive a real purge', async () => {
    // Create a contract WITHOUT migration_batch_id — must survive.
    const r = await adminQuery<{ id: number }>(
      `INSERT INTO contract (contract_number, title_en, contract_type, language, status,
                              created_by, updated_by, is_active, data_classification)
        VALUES ($1, $2, 'services', 'en', 'draft', $3, $3, TRUE, 'demo') RETURNING id`,
      [`NATIVE-${RUN}`, `Native ${RUN}`, PLATFORM_ADMIN.id],
    );
    const nativeId = r[0].id;
    trackedContractIds.push(nativeId);

    // Run real purge
    await callFn(PLATFORM_ADMIN.id, 'fn_migration_purge_all', [false]);

    // Native contract must still exist
    const survive = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count FROM contract WHERE id = $1`,
      [nativeId],
    );
    expect(parseInt(survive[0].count)).toBe(1);

    // OAuth connections survive
    const conns = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count FROM external_connection WHERE id = ANY($1::bigint[])`,
      [trackedConnIds.length > 0 ? trackedConnIds : [0]],
    );
    expect(parseInt(conns[0].count)).toBeGreaterThan(0);
  });
});

// ────────────────────────────────────────────────────────────────────────────
// 5. S2-21 — no PUBLIC EXECUTE on any new fn_
// ────────────────────────────────────────────────────────────────────────────

describe('M22 — S2-21 PUBLIC EXECUTE compliance', () => {
  it('all fn_external_connection_* / fn_migration_* fns have NULL proacl or are PUBLIC-revoked', async () => {
    const r = await adminQuery<{ name: string; proacl: string | null }>(
      `SELECT proname AS name, proacl::text AS proacl
         FROM pg_proc
        WHERE pronamespace = 'public'::regnamespace
          AND (proname LIKE 'fn_external_connection_%'
               OR proname LIKE 'fn_migration_%'
               OR proname = 'fn_require_tenant_guc')`,
    );
    expect(r.length).toBeGreaterThan(15);
    for (const row of r) {
      // NULL proacl => default no-PUBLIC; otherwise PUBLIC must not be granted
      if (row.proacl) {
        expect(row.proacl).not.toMatch(/=X\/PUBLIC|PUBLIC=X/);
      }
    }
  });
});
