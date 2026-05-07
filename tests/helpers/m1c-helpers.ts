/**
 * Shared helpers for M1c (Bulk & Manual Import) integration + DB tests.
 *
 * Provides:
 *   - seedFixtureUsers()     — idempotent role-based test user pool
 *                               (drafter1, recipient1, approver1, approver2,
 *                                executive1, legal_counsel1) — addresses the
 *                                FIXTURE-USERS deferred follow-up from M1a.
 *   - signFixtureToken()     — produce a valid M0 access token for a fixture user
 *                               without going through /auth/login (the bcrypt
 *                                hash for 'disabled' password) — login flow is
 *                                exercised by the bootstrap admin in m1a-helpers.
 *   - createImportBatch()    — POST /api/v1/import-batches wrapper
 *   - cleanupImportBatchesByIds — bypass-RLS hard-delete for test cleanup
 *   - cleanupImportBatchesByPrefix — alternative cleanup by initiated_by user id
 *
 * Bootstrap fixture password is 'TestPass!23' for any fixture user, hashed with
 * bcrypt 12 rounds. We re-use the bcrypt hash from M1b-rls helper rather than
 * re-hashing each time — bcrypt is intentionally slow and there is no test
 * benefit to a fresh hash.
 *
 * Cleanup model:
 *   - Fixture users + ephemeral roles are persisted across test files (kept
 *     in the test branch — idempotent on re-run).
 *   - Import batches created during a test run are tracked and hard-deleted in
 *     afterAll via the BYPASSRLS admin pool (audit_log rows for batch_id are
 *     cleaned with a CASCADE DELETE since import_batch.id has no FK from
 *     audit_log; we filter by table_name='import_batch' instead).
 */
import { adminPool, adminQuery } from './m1a-helpers';
import { signAccessToken } from '../../src/utils/jwt.util';

/**
 * Bcrypt hash of 'TestPass!23' (cost=12). Generated once and re-used across
 * fixture rows so beforeAll setup stays fast.
 *
 * NOTE: This hash is also used in m1b-rls-payment-schedule-with-check.test.ts
 * for a 'disabled' literal password — but those rows never log in. Here we
 * use a real-looking password and seal it with the standard cost factor so
 * any future code path that exercises the password column (admin reset, etc.)
 * can re-verify. Tests skip the /auth/login round-trip and mint the JWT
 * directly via signAccessToken to avoid the bcrypt cost in the inner test loop.
 */
const FIXTURE_PASSWORD_HASH =
  '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS';

export interface FixtureUserSpec {
  /** Friendly handle used as a Map key — drafter1 / approver1 / etc. */
  handle: string;
  /** Stable email — used by INSERT ... ON CONFLICT (email) DO UPDATE. */
  email: string;
  firstName: string;
  lastName: string;
  /** Existing role.name in the seeded role catalog. */
  roleName: string;
  /**
   * Permission codes that must be granted ad-hoc on TOP OF the role's
   * default seed grants. Used when a fixture user needs a permission the
   * canonical role does not carry — e.g. legal_counsel1 also needs
   * 'import.review' (which IS already granted by 018, so empty). Kept
   * for forward compat.
   */
  extraPermissions?: ReadonlyArray<string>;
}

/**
 * Canonical fixture user pool. Cumulative deferred follow-up since M1a
 * (FIXTURE-USERS / 16 ACs). M1c is the natural place to introduce these.
 *
 * Roles already exist (migration 003 / 001). Permissions already grant
 * (018 for import.*; 003 for contract.*).
 */
export const FIXTURE_USERS: ReadonlyArray<FixtureUserSpec> = [
  {
    handle: 'drafter1',
    email: 'fixture-drafter1@m1c.test',
    firstName: 'Fixture',
    lastName: 'Drafter1',
    roleName: 'contract_drafter',
    // contract_drafter already has import.run + import.review (018) +
    // contract.draft + contract.edit + contract.tag.manage (003).
    extraPermissions: [],
  },
  {
    handle: 'recipient1',
    email: 'fixture-recipient1@m1c.test',
    firstName: 'Fixture',
    lastName: 'Recipient1',
    roleName: 'contract_recipient',
    // contract_recipient has only contract.read.own (003). No import.*.
    extraPermissions: [],
  },
  {
    handle: 'approver1',
    email: 'fixture-approver1@m1c.test',
    firstName: 'Fixture',
    lastName: 'Approver1',
    roleName: 'contract_approver',
    extraPermissions: [],
  },
  {
    handle: 'approver2',
    email: 'fixture-approver2@m1c.test',
    firstName: 'Fixture',
    lastName: 'Approver2',
    roleName: 'contract_approver_2',
    extraPermissions: [],
  },
  {
    handle: 'executive1',
    email: 'fixture-executive1@m1c.test',
    firstName: 'Fixture',
    lastName: 'Executive1',
    roleName: 'executive',
    extraPermissions: [],
  },
  {
    handle: 'legal_counsel1',
    email: 'fixture-legal1@m1c.test',
    firstName: 'Fixture',
    lastName: 'LegalCounsel1',
    roleName: 'legal_counsel',
    // legal_counsel already has import.review (018). No extras needed.
    extraPermissions: [],
  },
  {
    handle: 'platform_admin1',
    email: 'fixture-platformadmin1@m1c.test',
    firstName: 'Fixture',
    lastName: 'PlatformAdmin1',
    roleName: 'platform_admin',
    // platform_admin gains user.read.all + user.manage + audit.read via 094.
    extraPermissions: [],
  },
];

export interface SeededFixtureUser {
  id: number;
  handle: string;
  email: string;
  roleId: number;
  roleName: string;
  /**
   * Permission codes the user effectively holds (role grants + extraPermissions).
   * Read from role_permission at seed time — used only for sanity assertions.
   */
  permissions: ReadonlyArray<string>;
}

let _fixtureUsersByHandle: Map<string, SeededFixtureUser> | null = null;

/**
 * Idempotently seed the canonical fixture user pool. Returns a Map keyed by
 * the friendly handle. Safe to call multiple times — uses ON CONFLICT (email)
 * DO UPDATE so re-runs against the same test branch are no-ops on the second
 * invocation.
 *
 * Per beM1c BE-RLS-fixture-handoff: users are real DB rows so RLS predicates
 * that read `app.current_user_id` evaluate correctly when a test sets the GUC
 * to one of these ids.
 */
export const seedFixtureUsers = async (): Promise<
  Map<string, SeededFixtureUser>
> => {
  if (_fixtureUsersByHandle) return _fixtureUsersByHandle;

  const pool = adminPool();
  const client = await pool.connect();
  const map = new Map<string, SeededFixtureUser>();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');

    for (const spec of FIXTURE_USERS) {
      const roleRes = await client.query<{ id: number | string }>(
        'SELECT id FROM role WHERE name = $1 AND is_active = TRUE',
        [spec.roleName],
      );
      const rawRoleId = roleRes.rows[0]?.id;
      if (rawRoleId === undefined || rawRoleId === null) {
        throw new Error(
          `Fixture role '${spec.roleName}' not found — was migration 003 applied?`,
        );
      }
      const roleId = Number(rawRoleId);
      if (!Number.isFinite(roleId)) {
        throw new Error(
          `Fixture role '${spec.roleName}' has non-numeric id: ${String(rawRoleId)}`,
        );
      }

      // Upsert user — idempotent. Bootstrap admin (id=1) is the creator.
      const userRes = await client.query<{ id: number | string }>(
        `INSERT INTO "user"
           (email, password_hash, first_name, last_name, role_id, is_active, created_by, updated_by)
           VALUES ($1, $2, $3, $4, $5, TRUE, 1, 1)
         ON CONFLICT (email) DO UPDATE
           SET first_name = EXCLUDED.first_name,
               last_name  = EXCLUDED.last_name,
               role_id    = EXCLUDED.role_id,
               is_active  = TRUE,
               updated_by = 1
         RETURNING id`,
        [spec.email, FIXTURE_PASSWORD_HASH, spec.firstName, spec.lastName, roleId],
      );
      const userId = Number(userRes.rows[0]!.id);

      // Apply any extra permission grants idempotently.
      for (const code of spec.extraPermissions ?? []) {
        await client.query(
          `INSERT INTO role_permission (role_id, permission_id, is_active, created_by)
             SELECT $1, p.id, TRUE, 1 FROM permission p WHERE p.code = $2
           ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = TRUE`,
          [roleId, code],
        );
      }

      // Read effective permissions for telemetry only.
      const permRes = await client.query<{ code: string }>(
        `SELECT DISTINCT p.code
           FROM permission p
           JOIN role_permission rp ON rp.permission_id = p.id AND rp.is_active = TRUE
          WHERE rp.role_id = $1`,
        [roleId],
      );
      const permissions = permRes.rows.map((r) => r.code);

      map.set(spec.handle, {
        id: userId,
        handle: spec.handle,
        email: spec.email,
        roleId,
        roleName: spec.roleName,
        permissions,
      });
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

  _fixtureUsersByHandle = map;
  return map;
};

/**
 * Return a SeededFixtureUser by handle. Throws if seedFixtureUsers() was not
 * called first (deliberate — we never want a test to silently use a stale
 * cached map across suites).
 */
export const getFixture = (handle: string): SeededFixtureUser => {
  if (!_fixtureUsersByHandle) {
    throw new Error('seedFixtureUsers() must be called from beforeAll');
  }
  const u = _fixtureUsersByHandle.get(handle);
  if (!u) throw new Error(`Fixture user '${handle}' not seeded`);
  return u;
};

/**
 * Mint a valid access token for the given fixture user — bypasses /auth/login
 * because the bcrypt cost dominates test runtime and we already trust M0's
 * password verification (covered by auth.test.ts).
 *
 * Note: req.permissions is read by `authenticate` middleware via fn_user_get_by_id,
 * not from the JWT. So the token need only carry `sub` + `role`; permission
 * lookup happens server-side from the role at request time.
 */
export const signFixtureToken = (handle: string): string => {
  const u = getFixture(handle);
  return signAccessToken({ userId: u.id, role: u.roleName });
};

// ----------------------------------------------------------------------------
// Import batch test helpers
// ----------------------------------------------------------------------------

/**
 * Seed an import_batch row directly via fn_import_batch_create using the
 * BYPASSRLS pool (with `app.current_user_id` set to the fixture user's id so
 * fn_'s own permission gate evaluates correctly).
 *
 * Returns the new batch id.
 */
export const seedImportBatch = async (
  initiatedByUserId: number,
  payload: {
    totalFiles: number;
    config?: {
      contractType?: string;
      statusMode?: 'active' | 'draft' | 'auto';
      defaultCounterpartyId?: number;
    };
  },
): Promise<{ id: number; status: string }> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // Set GUC so fn_ defense-in-depth permission check evaluates the
    // initiatedByUser's effective permissions (not neondb_owner's).
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [
      String(initiatedByUserId),
    ]);
    const result = await client.query<{ created: { id: number; status: string } }>(
      'SELECT fn_import_batch_create($1::JSONB, $2::BIGINT) AS created',
      [JSON.stringify(payload), initiatedByUserId],
    );
    await client.query('COMMIT');
    const created = result.rows[0]?.created;
    if (!created || typeof created.id !== 'number') {
      throw new Error('seedImportBatch failed: unexpected response shape');
    }
    return created;
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
 * Hard-delete import_batch rows + their audit_log rows by id. Used by
 * afterAll cleanup. Skips gracefully when the list is empty.
 */
export const cleanupImportBatchesByIds = async (ids: number[]): Promise<void> => {
  if (ids.length === 0) return;
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    // Detach any contracts pointing at these batches FIRST (FK ON DELETE
    // SET NULL covers this, but we also clear non-FK metadata fields like
    // import_filename / import_confidence so test contracts don't carry
    // stale links).
    await client.query(
      `UPDATE contract
          SET import_batch_id  = NULL,
              import_confidence = NULL,
              import_warnings   = NULL,
              import_filename   = NULL
        WHERE import_batch_id = ANY($1::BIGINT[])`,
      [ids],
    );
    // Audit rows for these batches.
    await client.query(
      `DELETE FROM audit_log
        WHERE table_name = 'import_batch'
          AND record_id  = ANY($1::BIGINT[])`,
      [ids],
    );
    // Then the batches themselves. RESTRICTIVE policy
    // import_batch_deny_direct_delete uses USING(FALSE) — but neondb_owner
    // has BYPASSRLS so the DELETE proceeds.
    await client.query(
      'DELETE FROM import_batch WHERE id = ANY($1::BIGINT[])',
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
 * Test-only helper — toggle import_batch.is_active directly, bypassing the
 * trg_import_batch_immutable_fields BEFORE UPDATE trigger added by migration 021.
 *
 * Why this exists: migration 021 (Codex BE round-1 finding C1) replaced the
 * self-referencing RLS subquery anti-pattern with a BEFORE UPDATE trigger that
 * raises SQLSTATE 42501 whenever is_active OR initiated_by is changed. In
 * production this is correct — there is no fn_ that flips is_active; soft-
 * cancellation goes through status='cancelled'. But the AC-S3-08 / AC-S4-02
 * tests need to ARRANGE an is_active=FALSE row to verify that fn_import_batch_list
 * and fn_import_batch_get_by_id exclude/return-null for soft-deleted batches.
 *
 * Approach: temporarily DISABLE the named trigger, run the UPDATE, then re-
 * ENABLE it — all inside a single transaction. ALTER TABLE ... DISABLE TRIGGER
 * requires only table ownership (which neondb_owner has on the test branch);
 * SET session_replication_role would need SUPERUSER, which Neon does not grant.
 * The DISABLE+ENABLE is idempotent and confined to the helper transaction.
 *
 * SAFETY: only callable via the BYPASSRLS admin pool. Production code paths
 * (BE controllers + fn_ functions) cannot reach this — they go through the
 * BE pool which does not have BYPASSRLS and cannot ALTER TABLE.
 */
export const setImportBatchActiveBypassTrigger = async (
  id: number,
  value: boolean,
): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      'ALTER TABLE import_batch DISABLE TRIGGER trg_import_batch_immutable_fields',
    );
    try {
      await client.query(
        'UPDATE import_batch SET is_active = $1 WHERE id = $2',
        [value, id],
      );
    } finally {
      await client.query(
        'ALTER TABLE import_batch ENABLE TRIGGER trg_import_batch_immutable_fields',
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
 * Diagnostic helper — read a single batch row in raw form (audit columns +
 * counters + status) for assertions that the HTTP API may not surface.
 */
export const readBatchRowAdmin = async (
  id: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, initiated_by, total_files, auto_saved, review_queue,
            manual_entry, duplicates_skipped, errored, status, config,
            started_at, completed_at, is_active, created_at, updated_at
       FROM import_batch
      WHERE id = $1`,
    [id],
  );
  return rows[0] ?? null;
};

/**
 * Reset the cached fixture-user map. Useful between suites that explicitly
 * mutate roles or permissions and want a fresh re-read.
 */
export const resetFixtureCache = (): void => {
  _fixtureUsersByHandle = null;
};
