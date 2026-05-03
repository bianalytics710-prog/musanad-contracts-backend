/**
 * M1a — Concurrency regression tests for Codex BE-001 / BE-002 / BE-003.
 *
 * These tests use TWO independent PG clients drawn from the bypass-RLS admin
 * pool to drive interleaved transactions against the live test branch. They
 * call the fn_ functions directly (not through HTTP) because we need precise
 * control over BEGIN / commit timing — the Express layer wraps every request
 * in its own implicit txn boundary which makes deterministic interleaving
 * impossible.
 *
 * Each test:
 *   1. Seeds prerequisite rows via the admin pool.
 *   2. Opens two clients, BEGIN on each.
 *   3. Drives a specific interleaving that would expose the race if the
 *      FOR UPDATE was missing.
 *   4. Asserts that exactly one outcome holds — either one txn succeeds
 *      and the other fails with a documented error, OR one waits for the
 *      other and observes the committed state.
 *   5. Cleans up via the per-suite createdIds list.
 *
 * BE-001 — child create/update vs parent soft-delete:
 *   We start fn_contract_delete on the parent in T1, then attempt
 *   fn_contract_create / fn_contract_update referencing that parent in T2.
 *   T2 must block on the FOR UPDATE; whichever commits first wins the
 *   race; the other receives a documented error. The forbidden outcome
 *   is `child active AND parent inactive` — the test asserts the
 *   invariant directly via a post-commit query.
 *
 * BE-002 — concurrent body updates create stale version snapshots:
 *   Two updates change the same contract's body_en to different values.
 *   Both should serialise via the head-row FOR UPDATE. After both commit,
 *   the test asserts every contract_version row's body_en appears in the
 *   set of values that were ever committed to the head row — i.e. no
 *   "ghost" version row built from a stale read.
 *
 * BE-003 — concurrent tag-set replacement:
 *   Two fn_contract_set_tags calls with disjoint replacement arrays
 *   ({A->[B]}, {A->[C]}) must serialise. The final tag set must be
 *   exactly {[B]} or {[C]}, never the merged hybrid {[B, C]}.
 */
import { describe, it, expect, beforeAll, afterAll, vi } from 'vitest';
import {
  adminPool,
  adminQuery,
  cleanupContractsByIds,
  closeAdminPool,
} from '../helpers/m1a-helpers';

const ADMIN_ID = 1;

const createdIds: number[] = [];

const trackId = (id: number): number => {
  if (typeof id === 'number') createdIds.push(id);
  return id;
};

/** Seed a single contract directly via fn_contract_create. */
const seedContract = async (titleEn: string, bodyEn?: string): Promise<number> => {
  const rows = await adminQuery<{ created: { id: number } }>(
    `SELECT fn_contract_create($1::JSONB, $2::BIGINT) AS created`,
    [
      JSON.stringify({
        titleEn,
        contractType: 'employment',
        language: 'en',
        ...(bodyEn !== undefined ? { bodyEn } : {}),
      }),
      ADMIN_ID,
    ],
  );
  const id = rows[0]?.created?.id;
  if (typeof id !== 'number') {
    throw new Error(`seedContract failed: ${JSON.stringify(rows[0])}`);
  }
  return trackId(id);
};

beforeAll(async () => {
  // Touch the pool so a connection error fails fast.
  const c = await adminPool().connect();
  c.release();
});

afterAll(async () => {
  if (createdIds.length > 0) {
    try {
      await cleanupContractsByIds(createdIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M1a-concurrency-cleanup] failed to delete some rows:', err);
    }
  }
  await closeAdminPool();
});

// ============================================================================
// BE-001 — parent soft-delete vs child create/update race
// ============================================================================
describe('BE-001 — parent soft-delete races child create/update', () => {
  it('Codex-BE-001-a: concurrent fn_contract_delete(parent) + fn_contract_create(child) cannot leave an active child under a soft-deleted parent', async () => {
    vi.setConfig({ testTimeout: 15000 });

    const parentId = await seedContract('BE-001-a-parent');

    const pool = adminPool();
    const t1 = await pool.connect();
    const t2 = await pool.connect();
    let t1Result: 'committed' | 'failed' = 'failed';
    let t2Result: 'committed' | 'failed' = 'failed';
    let t2ChildId: number | null = null;
    let t1Error: string | null = null;
    let t2Error: string | null = null;

    try {
      await t1.query('BEGIN');
      await t1.query('SET LOCAL row_security = off');
      await t2.query('BEGIN');
      await t2.query('SET LOCAL row_security = off');

      // T1: take FOR UPDATE on the parent inside fn_contract_delete by
      // running fn_contract_delete itself. We don't COMMIT yet — we want
      // T2 to attempt its own parent FOR UPDATE and block.
      const t1DeletePromise = t1.query<{ deleted: { success: boolean } }>(
        `SELECT fn_contract_delete($1::BIGINT, $2::BIGINT) AS deleted`,
        [parentId, ADMIN_ID],
      );

      // Wait for T1 to acquire its lock before issuing T2.
      await t1DeletePromise;

      // T2: try to create a child referencing the about-to-be-deleted parent.
      // The fix forces fn_contract_create to attempt a FOR UPDATE on the
      // parent → it MUST block on T1's lock.
      const t2CreatePromise = t2
        .query<{ created: { id: number } }>(
          `SELECT fn_contract_create($1::JSONB, $2::BIGINT) AS created`,
          [
            JSON.stringify({
              titleEn: 'BE-001-a-child',
              contractType: 'employment',
              language: 'en',
              parentContractId: parentId,
            }),
            ADMIN_ID,
          ],
        )
        .then(
          (r) => {
            t2ChildId = r.rows[0]?.created?.id ?? null;
            if (t2ChildId !== null) trackId(t2ChildId);
            return 'ok' as const;
          },
          (err: Error) => {
            t2Error = err.message;
            return 'err' as const;
          },
        );

      // Give T2 a short tick to definitely block on the lock.
      await new Promise((resolve) => setTimeout(resolve, 200));

      // Now commit T1 — T2 unblocks.
      try {
        await t1.query('COMMIT');
        t1Result = 'committed';
      } catch (err) {
        t1Error = err instanceof Error ? err.message : String(err);
      }

      // T2 either: (a) succeeds because T1 hadn't committed parent inactive
      // yet (impossible here — T1 committed first), or (b) fails because
      // the locked parent is now is_active=false and the AND is_active=TRUE
      // filter rejects it.
      const t2Outcome = await t2CreatePromise;
      if (t2Outcome === 'ok') {
        try {
          await t2.query('COMMIT');
          t2Result = 'committed';
        } catch (err) {
          t2Error = err instanceof Error ? err.message : String(err);
        }
      } else {
        try {
          await t2.query('ROLLBACK');
        } catch {
          /* swallow */
        }
      }
    } finally {
      try {
        if (t1Result !== 'committed') await t1.query('ROLLBACK');
      } catch {
        /* swallow */
      }
      try {
        if (t2Result !== 'committed' && t2ChildId === null) await t2.query('ROLLBACK');
      } catch {
        /* swallow */
      }
      t1.release();
      t2.release();
    }

    // Invariant: there cannot be an active child under a soft-deleted parent.
    const orphanRows = await adminQuery<{ id: number; is_active: boolean }>(
      `SELECT c.id, c.is_active
         FROM contract c
         WHERE c.parent_contract_id = $1
           AND c.is_active = TRUE
           AND EXISTS (SELECT 1 FROM contract p WHERE p.id = $1 AND p.is_active = FALSE)`,
      [parentId],
    );
    expect(orphanRows.length).toBe(0);

    // And exactly one of T1/T2 must have succeeded — OR T1 succeeded
    // (delete) and T2 was rejected because parent now inactive.
    if (t1Result === 'committed') {
      // Parent soft-deleted; child create must have failed.
      expect(t2Result).toBe('failed');
      expect(t2Error).toMatch(/parentContractId|fn_contract_create/);
    } else {
      // T1 failed (children-block-delete) — T2 must have succeeded.
      expect(t1Error).toMatch(/children|fn_contract_delete/);
      expect(t2Result).toBe('committed');
    }
  });

  it('Codex-BE-001-c: create-then-soft-delete ordering — T1 holds parent FOR UPDATE inside fn_contract_create; T2 fn_contract_delete(parent) blocks, then fails children-block-delete after T1 commits the active child', async () => {
    // Codex round 2 BE-R2-002: BE-001-a verified the delete-first ordering
    // (T1 deletes → T2 create blocked → create rejected). This sibling test
    // verifies the REVERSE ordering: T1 creates the child FIRST and holds
    // the parent FOR UPDATE lock; T2's fn_contract_delete on the parent must
    // block on that lock and, once T1 commits the active child, T2 must
    // observe child_count > 0 and reject with the 409 children-block-delete
    // path. The forbidden outcome is a soft-deleted parent with an active
    // child still pointing at it.
    vi.setConfig({ testTimeout: 15000 });

    const parentId = await seedContract('BE-001-c-parent');

    const pool = adminPool();
    const t1 = await pool.connect();
    const t2 = await pool.connect();
    let t1Result: 'committed' | 'failed' = 'failed';
    let t2Result: 'committed' | 'failed' = 'failed';
    let t1Error: string | null = null;
    let t2Error: string | null = null;
    let t1ChildId: number | null = null;

    try {
      await t1.query('BEGIN');
      await t1.query('SET LOCAL row_security = off');
      await t2.query('BEGIN');
      await t2.query('SET LOCAL row_security = off');

      // T1: invoke fn_contract_create with parentContractId=parentId. The 008
      // BE-001 fix takes SELECT FOR UPDATE on the parent inside the function,
      // and the txn does NOT release the lock until COMMIT. We synchronously
      // await the create call so by the time it returns, both the parent
      // FOR UPDATE row-lock AND the new child INSERT are present in T1's
      // open snapshot. We then keep T1 open without committing.
      const t1CreateRes = await t1.query<{ created: { id: number } }>(
        `SELECT fn_contract_create($1::JSONB, $2::BIGINT) AS created`,
        [
          JSON.stringify({
            titleEn: 'BE-001-c-child',
            contractType: 'employment',
            language: 'en',
            parentContractId: parentId,
          }),
          ADMIN_ID,
        ],
      );
      t1ChildId = t1CreateRes.rows[0]?.created?.id ?? null;

      // T2: try to soft-delete the parent. fn_contract_delete starts with
      // SELECT ... FOR UPDATE on parentId — it MUST block on T1's lock.
      const t2DeletePromise = t2
        .query(
          `SELECT fn_contract_delete($1::BIGINT, $2::BIGINT)`,
          [parentId, ADMIN_ID],
        )
        .then(
          () => 'ok' as const,
          (err: Error) => {
            t2Error = err.message;
            return 'err' as const;
          },
        );

      // Brief wait so T2 is definitely blocked on the parent lock.
      await new Promise((resolve) => setTimeout(resolve, 200));

      // Now commit T1 — T2 unblocks. T2's child-active count query will see
      // the just-committed active child and raise children-block-delete.
      try {
        await t1.query('COMMIT');
        t1Result = 'committed';
        if (t1ChildId !== null) trackId(t1ChildId);
      } catch (err) {
        t1Error = err instanceof Error ? err.message : String(err);
      }

      const t2Outcome = await t2DeletePromise;
      if (t2Outcome === 'ok') {
        try {
          await t2.query('COMMIT');
          t2Result = 'committed';
        } catch (err) {
          t2Error = err instanceof Error ? err.message : String(err);
        }
      } else {
        try {
          await t2.query('ROLLBACK');
        } catch {
          /* swallow */
        }
      }
    } finally {
      try {
        if (t1Result !== 'committed') await t1.query('ROLLBACK');
      } catch {
        /* swallow */
      }
      try {
        if (t2Result !== 'committed') await t2.query('ROLLBACK');
      } catch {
        /* swallow */
      }
      t1.release();
      t2.release();
    }

    // Invariant: never an active child under a soft-deleted parent.
    const orphanRows = await adminQuery<{ id: number }>(
      `SELECT c.id
         FROM contract c
         WHERE c.parent_contract_id = $1
           AND c.is_active = TRUE
           AND EXISTS (SELECT 1 FROM contract p WHERE p.id = $1 AND p.is_active = FALSE)`,
      [parentId],
    );
    expect(orphanRows.length).toBe(0);

    // Expected: T1 (create) committed; T2 (delete) failed with the
    // children-block-delete 409 path.
    expect(t1Result).toBe('committed');
    expect(t2Result).toBe('failed');
    expect(t2Error).toMatch(/children|fn_contract_delete/);

    // The parent must still be active because the delete was rejected.
    const parentRows = await adminQuery<{ is_active: boolean }>(
      `SELECT is_active FROM contract WHERE id = $1`,
      [parentId],
    );
    expect(parentRows[0]?.is_active).toBe(true);

    // The child created by T1 must be active and still pointing at the
    // (active) parent.
    expect(t1ChildId).not.toBeNull();
    const childRows = await adminQuery<{ is_active: boolean; parent_contract_id: number | string | null }>(
      `SELECT is_active, parent_contract_id FROM contract WHERE id = $1`,
      [t1ChildId!],
    );
    expect(childRows[0]?.is_active).toBe(true);
    // pg returns BIGINT as string by default — coerce both sides to Number.
    expect(Number(childRows[0]?.parent_contract_id)).toBe(parentId);
  });

  it('Codex-BE-001-d: create-then-soft-delete reverse — T2 holds parent FOR UPDATE inside fn_contract_delete; T1 fn_contract_create blocks, then fails parentContractId-not-found after T2 commits the soft-delete (forward ordering for the create-then-soft-delete pair)', async () => {
    // Codex round 2 BE-R2-002 counterpart to Codex-BE-001-c. This forward
    // ordering complements the reverse case so the BOTH-orderings invariant
    // is asserted: regardless of who acquires the parent lock first, the
    // system never permits an active child under a soft-deleted parent.
    // BE-001-a runs end-to-end against the same shape but races a
    // statement-level interleave from the deleting side; this -d test
    // mirrors the precise create-then-soft-delete framing the round 2
    // review called out as missing.
    vi.setConfig({ testTimeout: 15000 });

    const parentId = await seedContract('BE-001-d-parent');

    const pool = adminPool();
    const t1 = await pool.connect();
    const t2 = await pool.connect();
    let t1Result: 'committed' | 'failed' = 'failed';
    let t2Result: 'committed' | 'failed' = 'failed';
    let t1Error: string | null = null;
    let t2Error: string | null = null;
    let t1ChildId: number | null = null;

    try {
      await t1.query('BEGIN');
      await t1.query('SET LOCAL row_security = off');
      await t2.query('BEGIN');
      await t2.query('SET LOCAL row_security = off');

      // T2: take fn_contract_delete's FOR UPDATE on the parent first; do NOT
      // commit yet so the lock is held.
      await t2.query(`SELECT fn_contract_delete($1::BIGINT, $2::BIGINT)`, [parentId, ADMIN_ID]);

      // T1: try to create a child referencing the about-to-be-deleted parent.
      // The 008 BE-001 fix forces a SELECT FOR UPDATE on the parent → T1
      // MUST block on T2's lock.
      const t1CreatePromise = t1
        .query<{ created: { id: number } }>(
          `SELECT fn_contract_create($1::JSONB, $2::BIGINT) AS created`,
          [
            JSON.stringify({
              titleEn: 'BE-001-d-child',
              contractType: 'employment',
              language: 'en',
              parentContractId: parentId,
            }),
            ADMIN_ID,
          ],
        )
        .then(
          (r) => {
            t1ChildId = r.rows[0]?.created?.id ?? null;
            if (t1ChildId !== null) trackId(t1ChildId);
            return 'ok' as const;
          },
          (err: Error) => {
            t1Error = err.message;
            return 'err' as const;
          },
        );

      // Brief wait so T1 is definitely blocked on the parent lock.
      await new Promise((resolve) => setTimeout(resolve, 200));

      // Commit T2 — soft-deletes parent → T1 unblocks → T1's FOR UPDATE
      // returns no row (is_active filter excludes the now-soft-deleted
      // parent) → T1 raises parentContractId-not-found.
      try {
        await t2.query('COMMIT');
        t2Result = 'committed';
      } catch (err) {
        t2Error = err instanceof Error ? err.message : String(err);
      }

      const t1Outcome = await t1CreatePromise;
      if (t1Outcome === 'ok') {
        try {
          await t1.query('COMMIT');
          t1Result = 'committed';
        } catch (err) {
          t1Error = err instanceof Error ? err.message : String(err);
        }
      } else {
        try {
          await t1.query('ROLLBACK');
        } catch {
          /* swallow */
        }
      }
    } finally {
      try {
        if (t1Result !== 'committed' && t1ChildId === null) await t1.query('ROLLBACK');
      } catch {
        /* swallow */
      }
      try {
        if (t2Result !== 'committed') await t2.query('ROLLBACK');
      } catch {
        /* swallow */
      }
      t1.release();
      t2.release();
    }

    // Invariant: never an active child under a soft-deleted parent.
    const orphanRows = await adminQuery<{ id: number }>(
      `SELECT c.id
         FROM contract c
         WHERE c.parent_contract_id = $1
           AND c.is_active = TRUE
           AND EXISTS (SELECT 1 FROM contract p WHERE p.id = $1 AND p.is_active = FALSE)`,
      [parentId],
    );
    expect(orphanRows.length).toBe(0);

    // Expected: T2 (delete) committed; T1 (create) rejected with
    // parentContractId-not-found because the locked parent is now inactive.
    expect(t2Result).toBe('committed');
    expect(t1Result).toBe('failed');
    expect(t1Error).toMatch(/parentContractId|fn_contract_create/);

    // The parent must be soft-deleted.
    const parentRows = await adminQuery<{ is_active: boolean }>(
      `SELECT is_active FROM contract WHERE id = $1`,
      [parentId],
    );
    expect(parentRows[0]?.is_active).toBe(false);

    // No child row should have been committed by T1.
    expect(t1ChildId).toBeNull();
  });

  it('Codex-BE-001-b: concurrent fn_contract_delete(parent) + fn_contract_update(child SET parentContractId) cannot leave an active child under a soft-deleted parent', async () => {
    vi.setConfig({ testTimeout: 15000 });

    const parentId = await seedContract('BE-001-b-parent');
    const childId = await seedContract('BE-001-b-child');

    const pool = adminPool();
    const t1 = await pool.connect();
    const t2 = await pool.connect();
    let t1Result: 'committed' | 'failed' = 'failed';
    let t2Result: 'committed' | 'failed' = 'failed';
    let t1Error: string | null = null;
    let t2Error: string | null = null;

    try {
      await t1.query('BEGIN');
      await t1.query('SET LOCAL row_security = off');
      await t2.query('BEGIN');
      await t2.query('SET LOCAL row_security = off');

      // T1 holds the parent's FOR UPDATE lock via fn_contract_delete.
      await t1.query(`SELECT fn_contract_delete($1::BIGINT, $2::BIGINT)`, [parentId, ADMIN_ID]);

      // T2 tries to update the child to point at this parent.
      const t2UpdatePromise = t2
        .query(
          `SELECT fn_contract_update($1::BIGINT, $2::JSONB, $3::BIGINT)`,
          [
            childId,
            JSON.stringify({ parentContractId: parentId, relationshipType: 'amendment' }),
            ADMIN_ID,
          ],
        )
        .then(
          () => 'ok' as const,
          (err: Error) => {
            t2Error = err.message;
            return 'err' as const;
          },
        );

      await new Promise((resolve) => setTimeout(resolve, 200));

      try {
        await t1.query('COMMIT');
        t1Result = 'committed';
      } catch (err) {
        t1Error = err instanceof Error ? err.message : String(err);
      }

      const t2Outcome = await t2UpdatePromise;
      if (t2Outcome === 'ok') {
        try {
          await t2.query('COMMIT');
          t2Result = 'committed';
        } catch (err) {
          t2Error = err instanceof Error ? err.message : String(err);
        }
      } else {
        try {
          await t2.query('ROLLBACK');
        } catch {
          /* swallow */
        }
      }
    } finally {
      try {
        if (t1Result !== 'committed') await t1.query('ROLLBACK');
      } catch {
        /* swallow */
      }
      try {
        if (t2Result !== 'committed') await t2.query('ROLLBACK');
      } catch {
        /* swallow */
      }
      t1.release();
      t2.release();
    }

    // Invariant: child's parent_contract_id must NOT point to a soft-deleted parent.
    const stateRows = await adminQuery<{
      child_active: boolean;
      child_parent: number | null;
      parent_active: boolean;
    }>(
      `SELECT c.is_active   AS child_active,
              c.parent_contract_id AS child_parent,
              p.is_active   AS parent_active
         FROM contract c
         LEFT JOIN contract p ON p.id = c.parent_contract_id
         WHERE c.id = $1`,
      [childId],
    );
    const state = stateRows[0]!;
    if (state.child_active && state.child_parent !== null) {
      expect(state.parent_active).toBe(true);
    }

    // Exactly one txn must have succeeded.
    expect([t1Result, t2Result].filter((r) => r === 'committed').length).toBeGreaterThanOrEqual(1);
    if (t1Result === 'committed' && t2Result === 'committed') {
      // Both committed → must mean T1 committed first (delete) and T2's
      // FOR UPDATE then saw is_active=false and rejected. So we'd actually
      // expect t2Result='failed' in that case. If both 'committed' the fix
      // failed.
      throw new Error(
        `Both txns committed — race not serialised. t1Error=${t1Error} t2Error=${t2Error}`,
      );
    }
  });
});

// ============================================================================
// BE-002 — concurrent body updates produce stale version snapshots
// ============================================================================
describe('BE-002 — concurrent fn_contract_update body changes', () => {
  it('Codex-BE-002: every contract_version body_en is one of the values that was committed to the head row (no stale snapshot)', async () => {
    vi.setConfig({ testTimeout: 15000 });

    const id = await seedContract('BE-002-target', 'V0');

    const pool = adminPool();
    const t1 = await pool.connect();
    const t2 = await pool.connect();
    const committed: string[] = ['V0'];

    try {
      await t1.query('BEGIN');
      await t1.query('SET LOCAL row_security = off');
      await t2.query('BEGIN');
      await t2.query('SET LOCAL row_security = off');

      // T1 enters fn_contract_update with bodyEn=V1. The function takes
      // FOR UPDATE on the head row. T2 then enters with bodyEn=V2 — its
      // FOR UPDATE blocks on T1.
      const t1Promise = t1.query(
        `SELECT fn_contract_update($1::BIGINT, $2::JSONB, $3::BIGINT)`,
        [id, JSON.stringify({ bodyEn: 'V1', changeNote: 'T1->V1' }), ADMIN_ID],
      );

      // Await T1 to ensure it has acquired the head-row lock before T2 fires.
      await t1Promise;

      const t2Promise = t2.query(
        `SELECT fn_contract_update($1::BIGINT, $2::JSONB, $3::BIGINT)`,
        [id, JSON.stringify({ bodyEn: 'V2', changeNote: 'T2->V2' }), ADMIN_ID],
      );

      // Brief wait so T2 is definitely blocked on the lock.
      await new Promise((resolve) => setTimeout(resolve, 200));

      await t1.query('COMMIT');
      committed.push('V1');

      await t2Promise;
      await t2.query('COMMIT');
      committed.push('V2');
    } finally {
      t1.release();
      t2.release();
    }

    // Every contract_version row's body_en must be a member of the
    // committed-values set. The forbidden case is a version row whose
    // body_en doesn't match ANY value the head row ever held — that
    // would mean a snapshot was built from a stale read.
    const versionRows = await adminQuery<{ version_number: number; body_en: string | null }>(
      `SELECT version_number, body_en FROM contract_version WHERE contract_id = $1
         ORDER BY version_number ASC`,
      [id],
    );
    expect(versionRows.length).toBeGreaterThanOrEqual(2);
    for (const row of versionRows) {
      expect(committed).toContain(row.body_en);
    }

    // The final head-row body_en must be V2 (T2 was the second writer).
    const headRows = await adminQuery<{ body_en: string | null; current_version: number }>(
      `SELECT body_en, current_version FROM contract WHERE id = $1`,
      [id],
    );
    expect(headRows[0]?.body_en).toBe('V2');

    // The final contract_version row (highest version_number) must also
    // be V2 — proving the version snapshot reflects the post-UPDATE state,
    // not a stale pre-UPDATE read.
    const lastVersion = versionRows[versionRows.length - 1]!;
    expect(lastVersion.body_en).toBe('V2');
  });
});

// ============================================================================
// BE-003 — concurrent fn_contract_set_tags
// ============================================================================
describe('BE-003 — concurrent fn_contract_set_tags', () => {
  it('Codex-BE-003: two concurrent set_tags with different replacements result in exactly one of the inputs as the final active tag set (no merged hybrid)', async () => {
    vi.setConfig({ testTimeout: 15000 });

    const id = await seedContract('BE-003-target');
    // Seed initial tag = ['A'].
    await adminQuery(
      `SELECT fn_contract_set_tags($1::BIGINT, $2::TEXT[], $3::BIGINT)`,
      [id, ['A'], ADMIN_ID],
    );

    const pool = adminPool();
    const t1 = await pool.connect();
    const t2 = await pool.connect();

    try {
      await t1.query('BEGIN');
      await t1.query('SET LOCAL row_security = off');
      await t2.query('BEGIN');
      await t2.query('SET LOCAL row_security = off');

      // T1 acquires the head-row FOR UPDATE inside fn_contract_set_tags
      // and replaces tags with ['B']. We await so the lock is held when
      // T2 starts.
      await t1.query(
        `SELECT fn_contract_set_tags($1::BIGINT, $2::TEXT[], $3::BIGINT)`,
        [id, ['B'], ADMIN_ID],
      );

      // T2 starts its own set_tags; without the FOR UPDATE fix it would
      // proceed concurrently and merge. With the fix, this query blocks
      // until T1 commits.
      const t2Promise = t2.query(
        `SELECT fn_contract_set_tags($1::BIGINT, $2::TEXT[], $3::BIGINT)`,
        [id, ['C'], ADMIN_ID],
      );

      // Brief wait so T2 is definitely blocked.
      await new Promise((resolve) => setTimeout(resolve, 200));

      await t1.query('COMMIT');
      await t2Promise;
      await t2.query('COMMIT');
    } finally {
      t1.release();
      t2.release();
    }

    // Final active tag set on the contract.
    const tagRows = await adminQuery<{ tag: string }>(
      `SELECT tag FROM contract_tag WHERE contract_id = $1 AND is_active = TRUE ORDER BY tag`,
      [id],
    );
    const finalTags = tagRows.map((r) => r.tag);

    // The merged hybrid result {B, C} must NEVER appear. After the fix,
    // T2's diff is computed from T1's committed result ({B}), so T2
    // correctly removes B and adds C → final set {C}.
    expect(finalTags).not.toEqual(['B', 'C']);
    expect(finalTags).toEqual(['C']);
  });
});
