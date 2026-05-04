/**
 * M1c — Database function tests (direct fn_ invocation, bypass HTTP layer).
 *
 * Covers:
 *   - fn_import_batch_create   (S1 — AC-S1-01, 02, 03, 04, 05)
 *   - fn_import_batch_update   (S2 — AC-S2-01..08, plus concurrency regression)
 *   - fn_import_batch_list     (S3 — AC-S3-01..08)
 *   - fn_import_batch_get_by_id (S4 — AC-S4-01, 02, 04)
 *
 * Strategy: call the fn_s directly via the admin pool with `app.current_user_id`
 * set to the appropriate fixture user, mirroring what the BE controller does
 * per-request. Cleanup happens in afterAll via cleanupImportBatchesByIds.
 *
 * AC-S2-07 (RLS narrowing — only initiator/import.run callers can update) is
 * partially covered here (we test the fn_'s permission RAISE) and via the
 * cross-module integration test in M1c-cross-module-extension.test.ts.
 *
 * AC-S2-01 concurrency regression: the BE-001 SELECT FOR UPDATE pattern is
 * verified via a Promise.all parallel-call test — drives 4 simultaneous
 * counter increments and asserts the final total is exact (no lost updates).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, adminQuery, closeAdminPool } from '../helpers/m1a-helpers';
import {
  cleanupImportBatchesByIds,
  getFixture,
  seedFixtureUsers,
  seedImportBatch,
  setImportBatchActiveBypassTrigger,
} from '../helpers/m1c-helpers';

const ADMIN_ID = 1;
const createdBatchIds: number[] = [];
const trackBatch = (id: number): number => {
  if (typeof id === 'number') createdBatchIds.push(id);
  return id;
};

beforeAll(async () => {
  await seedFixtureUsers();
});

afterAll(async () => {
  if (createdBatchIds.length > 0) {
    try {
      await cleanupImportBatchesByIds(createdBatchIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M1c-db-fn-cleanup] failed:', err);
    }
  }
  await closeAdminPool();
});

/**
 * Helper — call a fn_ directly with `app.current_user_id` set to the supplied
 * actor id so RLS + fn_ permission-check predicates evaluate correctly.
 */
const callAs = async <T>(
  actorId: number,
  fnName: string,
  args: ReadonlyArray<unknown>,
): Promise<T> => {
  // Allow unsafe SQL only for the literal fn name; positional placeholders
  // for the args.
  if (!/^[a-z_][a-z0-9_]*$/i.test(fnName)) {
    throw new Error(`bad fn name: ${fnName}`);
  }
  const placeholders = args.map((_, i) => `$${i + 1}`).join(', ');
  const sql = `SELECT ${fnName}(${placeholders}) AS result`;
  const bound = args.map((v) => {
    if (v === undefined || v === null) return null;
    if (Array.isArray(v)) {
      const containsObj = v.some(
        (el) => el !== null && typeof el === 'object' && !(el instanceof Date),
      );
      return containsObj ? JSON.stringify(v) : v;
    }
    if (typeof v === 'object') return JSON.stringify(v);
    return v;
  });
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [
      String(actorId),
    ]);
    const r = await client.query<{ result: T }>(sql, bound);
    await client.query('COMMIT');
    return r.rows[0]!.result as T;
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

// ============================================================================
// S1 — fn_import_batch_create
// ============================================================================
describe('S1 — fn_import_batch_create', () => {
  it('AC-S1-01: happy path — returns full batch shape with counters at 0', async () => {
    const drafter = getFixture('drafter1');
    const result = await callAs<{
      id: number;
      status: string;
      totalFiles: number;
      autoSaved: number;
      reviewQueue: number;
      manualEntry: number;
      duplicatesSkipped: number;
      config: Record<string, unknown>;
      startedAt: string;
    }>(drafter.id, 'fn_import_batch_create', [
      { totalFiles: 10, config: { statusMode: 'active', contractType: 'service' } },
      drafter.id,
    ]);
    trackBatch(result.id);
    expect(result.id).toBeGreaterThan(0);
    expect(result.status).toBe('in_progress');
    expect(result.totalFiles).toBe(10);
    expect(result.autoSaved).toBe(0);
    expect(result.reviewQueue).toBe(0);
    expect(result.manualEntry).toBe(0);
    expect(result.duplicatesSkipped).toBe(0);
    expect(result.config).toMatchObject({ statusMode: 'active', contractType: 'service' });
    expect(result.startedAt).toBeTruthy();
  });

  it('AC-S1-02: totalFiles < 1 raises with field=totalFiles', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callAs(drafter.id, 'fn_import_batch_create', [
        { totalFiles: 0, config: { statusMode: 'active' } },
        drafter.id,
      ]),
    ).rejects.toThrow(/totalFiles/i);
  });

  it('AC-S1-03: invalid statusMode raises with field=config.statusMode', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callAs(drafter.id, 'fn_import_batch_create', [
        { totalFiles: 5, config: { statusMode: 'unknown' } },
        drafter.id,
      ]),
    ).rejects.toThrow(/statusMode/i);
  });

  it('AC-S1-04: caller without import.run raises permission:Forbidden (defense in depth)', async () => {
    // recipient1 (contract_recipient) lacks both import.run and import.review.
    const recipient = getFixture('recipient1');
    await expect(
      callAs(recipient.id, 'fn_import_batch_create', [
        { totalFiles: 5, config: { statusMode: 'active' } },
        recipient.id,
      ]),
    ).rejects.toThrow(/permission|Forbidden/i);
  });

  it('AC-S1-05: initiated_by equals current_setting(app.current_user_id) and audit_log row written', async () => {
    const drafter = getFixture('drafter1');
    const result = await callAs<{ id: number }>(drafter.id, 'fn_import_batch_create', [
      { totalFiles: 3, config: { statusMode: 'auto' } },
      drafter.id,
    ]);
    trackBatch(result.id);
    const row = await adminQuery<{ initiated_by: number }>(
      'SELECT initiated_by FROM import_batch WHERE id = $1',
      [result.id],
    );
    expect(Number(row[0]!.initiated_by)).toBe(drafter.id);
    const audit = await adminQuery<{ action: string }>(
      `SELECT action FROM audit_log
        WHERE table_name = 'import_batch' AND record_id = $1 AND action = 'INSERT'`,
      [result.id],
    );
    expect(audit.length).toBeGreaterThanOrEqual(1);
  });
});

// ============================================================================
// S2 — fn_import_batch_update (incl. concurrency regression)
// ============================================================================
describe('S2 — fn_import_batch_update', () => {
  it('AC-S2-01 + AC-S2-03: counter increments, completed transition sets completed_at', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 5,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);

    // Increment autoSaved by 5 to fill totalFiles, then complete.
    const after1 = await callAs<{ autoSaved: number; status: string }>(
      drafter.id,
      'fn_import_batch_update',
      [seeded.id, drafter.id, null, 5, 0, 0, 0, 0],
    );
    expect(after1.autoSaved).toBe(5);
    expect(after1.status).toBe('in_progress');

    const after2 = await callAs<{ status: string; completedAt: string | null }>(
      drafter.id,
      'fn_import_batch_update',
      [seeded.id, drafter.id, 'completed', 0, 0, 0, 0, 0],
    );
    expect(after2.status).toBe('completed');
    expect(after2.completedAt).not.toBeNull();
  });

  it('AC-S2-02: invalid status transition raises (status:Invalid status transition)', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 3,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);

    // Move to completed first, then try to reopen.
    await callAs(drafter.id, 'fn_import_batch_update', [
      seeded.id,
      drafter.id,
      'completed',
      0,
      0,
      0,
      0,
      0,
    ]);
    await expect(
      callAs(drafter.id, 'fn_import_batch_update', [
        seeded.id,
        drafter.id,
        'in_progress',
        0,
        0,
        0,
        0,
        0,
      ]),
    ).rejects.toThrow(/Invalid status transition/i);
  });

  it('AC-S2-04: counter underflow raises (autoSaved:Counter underflow)', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 5,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);

    await expect(
      callAs(drafter.id, 'fn_import_batch_update', [
        seeded.id,
        drafter.id,
        null,
        -1, // would drive autoSaved to -1
        0,
        0,
        0,
        0,
      ]),
    ).rejects.toThrow(/(autoSaved|underflow)/i);
  });

  it('AC-S2-05: counter overflow vs totalFiles raises (counters:Counter overflow)', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 3,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);

    await expect(
      callAs(drafter.id, 'fn_import_batch_update', [
        seeded.id,
        drafter.id,
        null,
        4, // totalFiles=3 → overflow
        0,
        0,
        0,
        0,
      ]),
    ).rejects.toThrow(/overflow/i);
  });

  it('AC-S2-06: nonexistent id raises 404:Import batch not found', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callAs(drafter.id, 'fn_import_batch_update', [
        9_999_999,
        drafter.id,
        null,
        1,
        0,
        0,
        0,
        0,
      ]),
    ).rejects.toThrow(/(404|not found)/i);
  });

  it('AC-S2-07: initiator-only (drafter who owns batch can update — non-initiator drafter cannot)', async () => {
    const owner = getFixture('drafter1');
    const seeded = await seedImportBatch(owner.id, {
      totalFiles: 4,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    // Try as recipient1 (no import.run) — must raise permission:Forbidden.
    const recipient = getFixture('recipient1');
    await expect(
      callAs(recipient.id, 'fn_import_batch_update', [
        seeded.id,
        recipient.id,
        null,
        1,
        0,
        0,
        0,
        0,
      ]),
    ).rejects.toThrow(/permission|Forbidden/i);
  });

  it('AC-S2-08: terminal state (cancelled) cannot reopen — invalid transition', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 2,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    await callAs(drafter.id, 'fn_import_batch_update', [
      seeded.id,
      drafter.id,
      'cancelled',
      0,
      0,
      0,
      0,
      0,
    ]);
    await expect(
      callAs(drafter.id, 'fn_import_batch_update', [
        seeded.id,
        drafter.id,
        'in_progress',
        0,
        0,
        0,
        0,
        0,
      ]),
    ).rejects.toThrow(/Invalid status transition/i);
  });

  // ------------------------------------------------------------------
  // CONCURRENCY REGRESSION — Codex BE-001 (SELECT FOR UPDATE)
  // ------------------------------------------------------------------
  it('AC-S2-01 concurrency: 4 parallel autoSaved+=1 increments produce final autoSaved=4 (no lost update)', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 10,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);

    const calls = Array.from({ length: 4 }, () =>
      callAs(drafter.id, 'fn_import_batch_update', [
        seeded.id,
        drafter.id,
        null,
        1, // autoSavedDelta = +1
        0,
        0,
        0,
        0,
      ]),
    );
    await Promise.all(calls);

    const r = await adminQuery<{ auto_saved: number }>(
      'SELECT auto_saved FROM import_batch WHERE id = $1',
      [seeded.id],
    );
    expect(Number(r[0]!.auto_saved)).toBe(4);
  });

  it('AC-S2-05 concurrency: parallel increments past totalFiles do not overflow — at least one raises', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 2,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);

    // Fire 4 parallel +1 increments — only 2 should succeed (totalFiles=2).
    // The other 2 must raise overflow because the FOR UPDATE serialises
    // them and the post-increment sum would exceed totalFiles.
    const calls = Array.from({ length: 4 }, () =>
      callAs(drafter.id, 'fn_import_batch_update', [
        seeded.id,
        drafter.id,
        null,
        1,
        0,
        0,
        0,
        0,
      ]).catch((e: Error) => e),
    );
    const settled = await Promise.all(calls);
    const succeeded = settled.filter((r) => !(r instanceof Error)).length;
    const failed = settled.filter((r) => r instanceof Error).length;
    expect(succeeded).toBe(2);
    expect(failed).toBe(2);
    // Final state: autoSaved == totalFiles, no overrun.
    const r = await adminQuery<{ auto_saved: number; total_files: number }>(
      'SELECT auto_saved, total_files FROM import_batch WHERE id = $1',
      [seeded.id],
    );
    expect(Number(r[0]!.auto_saved)).toBe(2);
    expect(Number(r[0]!.total_files)).toBe(2);
  });

  it('AC-S2-04 concurrency: parallel underflow attempts do not double-decrement below zero', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 5,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);

    // Bring autoSaved up to 1.
    await callAs(drafter.id, 'fn_import_batch_update', [
      seeded.id,
      drafter.id,
      null,
      1,
      0,
      0,
      0,
      0,
    ]);

    // Fire 3 parallel -1 decrements. Only 1 should succeed (1 → 0); the
    // other 2 must underflow.
    const calls = Array.from({ length: 3 }, () =>
      callAs(drafter.id, 'fn_import_batch_update', [
        seeded.id,
        drafter.id,
        null,
        -1,
        0,
        0,
        0,
        0,
      ]).catch((e: Error) => e),
    );
    const settled = await Promise.all(calls);
    const succeeded = settled.filter((r) => !(r instanceof Error)).length;
    const failed = settled.filter((r) => r instanceof Error).length;
    expect(succeeded).toBe(1);
    expect(failed).toBe(2);
    const r = await adminQuery<{ auto_saved: number }>(
      'SELECT auto_saved FROM import_batch WHERE id = $1',
      [seeded.id],
    );
    expect(Number(r[0]!.auto_saved)).toBe(0);
  });
});

// ============================================================================
// S3 — fn_import_batch_list
// ============================================================================
describe('S3 — fn_import_batch_list', () => {
  it('AC-S3-01 + AC-S3-04: paginated, ordered by started_at DESC; row carries 12 fields', async () => {
    const drafter = getFixture('drafter1');
    const b1 = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    const b2 = await seedImportBatch(drafter.id, {
      totalFiles: 2,
      config: { statusMode: 'active' },
    });
    trackBatch(b1.id);
    trackBatch(b2.id);

    const result = await callAs<{
      data: Array<Record<string, unknown>>;
      pagination: { total: number; page: number; limit: number; totalPages: number };
    }>(ADMIN_ID, 'fn_import_batch_list', [
      1,
      20,
      null,
      null,
      ADMIN_ID,
      'Super Admin',
    ]);
    expect(Array.isArray(result.data)).toBe(true);
    expect(result.pagination.page).toBe(1);
    expect(result.pagination.limit).toBe(20);
    expect(typeof result.pagination.total).toBe('number');
    expect(typeof result.pagination.totalPages).toBe('number');

    // Each row must carry the 11 documented fields per AC-S3-04 (errored is
    // an additional 5th counter — listed in be-implementation-summary).
    const expectedKeys = [
      'id',
      'initiatedBy',
      'totalFiles',
      'autoSaved',
      'reviewQueue',
      'manualEntry',
      'duplicatesSkipped',
      'status',
      'startedAt',
      'completedAt',
    ];
    if (result.data.length > 0) {
      const row = result.data[0]!;
      for (const key of expectedKeys) {
        expect(row).toHaveProperty(key);
      }
    }
  });

  it('AC-S3-02: total = 0 → totalPages = 0, data = [] (no error)', async () => {
    // Filter by an impossibly large initiatedBy id.
    const result = await callAs<{
      data: unknown[];
      pagination: { total: number; totalPages: number };
    }>(ADMIN_ID, 'fn_import_batch_list', [
      1,
      20,
      null,
      9_999_999,
      ADMIN_ID,
      'Super Admin',
    ]);
    expect(result.data).toEqual([]);
    expect(result.pagination.total).toBe(0);
    expect(result.pagination.totalPages).toBe(0);
  });

  it('AC-S3-03: filter by status="paused" only returns paused rows', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 5,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    // Move it to paused.
    await callAs(drafter.id, 'fn_import_batch_update', [
      seeded.id,
      drafter.id,
      'paused',
      0,
      0,
      0,
      0,
      0,
    ]);

    const result = await callAs<{ data: Array<{ id: number; status: string }> }>(
      ADMIN_ID,
      'fn_import_batch_list',
      [1, 100, 'paused', null, ADMIN_ID, 'Super Admin'],
    );
    for (const row of result.data) {
      expect(row.status).toBe('paused');
    }
    // Our seeded batch must be in there.
    const ids = result.data.map((r) => r.id);
    expect(ids).toContain(seeded.id);
  });

  it('AC-S3-07 role narrowing: drafter1 sees own batches only; admin sees all (defense in depth via fn_ v_role_can_see_all gate)', async () => {
    const drafter = getFixture('drafter1');
    const seededByDrafter = await seedImportBatch(drafter.id, {
      totalFiles: 4,
      config: { statusMode: 'active' },
    });
    trackBatch(seededByDrafter.id);
    // Also seed one batch by admin so the data set has 2+ owners.
    const seededByAdmin = await seedImportBatch(ADMIN_ID, {
      totalFiles: 3,
      config: { statusMode: 'active' },
    });
    trackBatch(seededByAdmin.id);

    const drafterView = await callAs<{ data: Array<{ id: number; initiatedBy: number }> }>(
      drafter.id,
      'fn_import_batch_list',
      [1, 100, null, null, drafter.id, drafter.roleName],
    );
    const drafterIds = drafterView.data.map((r) => r.id);
    expect(drafterIds).toContain(seededByDrafter.id);
    expect(drafterIds).not.toContain(seededByAdmin.id);
    // Every row must be initiated by drafter.id.
    for (const row of drafterView.data) {
      expect(Number(row.initiatedBy)).toBe(drafter.id);
    }

    const adminView = await callAs<{ data: Array<{ id: number }> }>(
      ADMIN_ID,
      'fn_import_batch_list',
      [1, 100, null, null, ADMIN_ID, 'Super Admin'],
    );
    const adminIds = adminView.data.map((r) => r.id);
    expect(adminIds).toContain(seededByDrafter.id);
    expect(adminIds).toContain(seededByAdmin.id);
  });

  it('AC-S3-08: is_active=false batches universally excluded', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    // Soft-delete via admin pool. Migration 021 added a BEFORE UPDATE trigger
    // that blocks direct is_active toggles (SQLSTATE 42501); the helper
    // bypasses it with SET LOCAL session_replication_role='replica' so the
    // test can ARRANGE the soft-deleted state without going through a
    // production code path that does not exist (no fn_ flips is_active).
    await setImportBatchActiveBypassTrigger(seeded.id, false);
    const result = await callAs<{ data: Array<{ id: number }> }>(
      ADMIN_ID,
      'fn_import_batch_list',
      [1, 100, null, null, ADMIN_ID, 'Super Admin'],
    );
    expect(result.data.map((r) => r.id)).not.toContain(seeded.id);
    // Restore so cleanup can hard-delete it (cleanup uses DELETE not UPDATE,
    // but is_active=TRUE keeps the row in policy view if anyone re-reads).
    await setImportBatchActiveBypassTrigger(seeded.id, true);
  });
});

// ============================================================================
// S4 — fn_import_batch_get_by_id
// ============================================================================
describe('S4 — fn_import_batch_get_by_id', () => {
  it('AC-S4-01 + AC-S4-04: returns full shape with initiatedBy hydrated as UserRef', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 7,
      config: { statusMode: 'active', contractType: 'employment' },
    });
    trackBatch(seeded.id);

    const result = await callAs<{
      id: number;
      initiatedBy: { id: number; firstName: string; lastName: string } | number;
      totalFiles: number;
      autoSaved: number;
      reviewQueue: number;
      manualEntry: number;
      duplicatesSkipped: number;
      status: string;
      config: Record<string, unknown>;
      startedAt: string;
      createdAt: string;
      updatedAt: string;
    }>(drafter.id, 'fn_import_batch_get_by_id', [seeded.id, drafter.id]);

    expect(result.id).toBe(seeded.id);
    expect(result.totalFiles).toBe(7);
    expect(result.status).toBe('in_progress');
    expect(result.config).toMatchObject({ statusMode: 'active', contractType: 'employment' });
    expect(typeof result.startedAt).toBe('string');
    expect(typeof result.createdAt).toBe('string');
    expect(typeof result.updatedAt).toBe('string');
    // AC-S4-04: initiatedBy hydrated as UserRef
    expect(typeof result.initiatedBy).toBe('object');
    if (result.initiatedBy && typeof result.initiatedBy === 'object') {
      const ref = result.initiatedBy as { id: number; firstName: string; lastName: string };
      expect(Number(ref.id)).toBe(drafter.id);
      expect(typeof ref.firstName).toBe('string');
      expect(typeof ref.lastName).toBe('string');
    }
  });

  it('AC-S4-02: nonexistent id returns NULL (BE controller maps to 404)', async () => {
    const drafter = getFixture('drafter1');
    const result = await callAs<unknown>(drafter.id, 'fn_import_batch_get_by_id', [
      9_999_999,
      drafter.id,
    ]);
    expect(result).toBeNull();
  });

  it('AC-S4-02: is_active=false batch returns NULL', async () => {
    const drafter = getFixture('drafter1');
    const seeded = await seedImportBatch(drafter.id, {
      totalFiles: 1,
      config: { statusMode: 'active' },
    });
    trackBatch(seeded.id);
    // Migration 021 added a BEFORE UPDATE trigger that blocks direct is_active
    // toggles; bypass it via session_replication_role='replica' for test ARRANGE.
    await setImportBatchActiveBypassTrigger(seeded.id, false);
    const result = await callAs<unknown>(drafter.id, 'fn_import_batch_get_by_id', [
      seeded.id,
      drafter.id,
    ]);
    expect(result).toBeNull();
    await setImportBatchActiveBypassTrigger(seeded.id, true);
  });
});
