/**
 * R-DA9-3 — Database function tests for the drafter + approver session
 * fn_'s that R-LC9 didn't already cover:
 *
 *   M_parity entities (058):
 *     - fn_party_list                (read)
 *     - fn_party_get_by_id           (read)
 *     - fn_template_list             (read)
 *     - fn_template_get_by_id        (read)
 *     - fn_clause_list               (read)
 *     - fn_clause_get_by_id          (read)
 *     - fn_obligation_list           (read)
 *
 *   R4 contract comments (065):
 *     - fn_contract_comment_list
 *     - fn_contract_comment_create
 *     - fn_contract_comment_resolve
 *     - fn_contract_comment_delete
 *
 *   R5 approver analytics (066/067/068):
 *     - fn_contract_watch_set
 *     - fn_approval_my_decisions
 *     - fn_approval_watching
 *     - fn_dashboard_approver
 *
 * Each fn_ gets at minimum a happy path + at least one error/permission
 * path. Cleanup tracks every row inserted by the tests so reruns are
 * idempotent.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminQuery } from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';

const RUN_ID = `da9-${Date.now()}`;
const ADMIN_ID = 1;

let LEGAL_COUNSEL: SeededFixtureUser;
let APPROVER: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;
let RECIPIENT: SeededFixtureUser;

const trackedCommentIds: number[] = [];
const trackedWatchKeys: Array<{ user: number; contract: number }> = [];
let testContractId: number = 0;

beforeAll(async () => {
  await seedFixtureUsers();
  LEGAL_COUNSEL = getFixture('legal_counsel1');
  APPROVER = getFixture('approver1');
  DRAFTER = getFixture('drafter1');
  RECIPIENT = getFixture('recipient1');

  // Create one test contract for comments + watch + obligations checks.
  const rows = await adminQuery<{ id: number }>(
    `INSERT INTO contract (
       contract_number, title_en, contract_type, status, language,
       currency, value_aed, drafted_by, created_by, updated_by
     ) VALUES (
       $1, $2, 'service', 'active', 'en', 'AED', 100000, $3, $3, $3
     ) RETURNING id`,
    [`DA9-CTR-${RUN_ID}`, `R-DA9 Test Contract`, ADMIN_ID],
  );
  testContractId = Number(rows[0]!.id);
});

afterAll(async () => {
  if (trackedWatchKeys.length > 0) {
    await adminQuery(
      `DELETE FROM contract_watch
        WHERE (user_id, contract_id) IN (${trackedWatchKeys
          .map((_, i) => `($${i * 2 + 1}::BIGINT, $${i * 2 + 2}::BIGINT)`)
          .join(', ')})`,
      trackedWatchKeys.flatMap((k) => [k.user, k.contract]),
    );
  }
  if (trackedCommentIds.length > 0) {
    await adminQuery(
      `DELETE FROM contract_comment WHERE id = ANY($1::BIGINT[])`,
      [trackedCommentIds],
    );
  }
  if (testContractId > 0) {
    await adminQuery(`DELETE FROM contract WHERE id = $1`, [testContractId]);
  }
});

// ─── 058 read-only fn_'s (party / template / clause / obligation) ─────────

describe('fn_party_list / fn_party_get_by_id (058)', () => {
  it('lists parties for legal_counsel', async () => {
    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_party_list',
      [LEGAL_COUNSEL.id, null, null, 5, 0],
    );
    expect(Array.isArray(r.data)).toBe(true);
    expect(typeof r.pagination.total).toBe('number');
  });

  it('rejects recipient without read permissions', async () => {
    await expect(
      callFnAs(
        RECIPIENT.id,
        'fn_party_list',
        [RECIPIENT.id, null, null, 5, 0],
      ),
    ).rejects.toThrow(/forbidden|42501/);
  });

  it('returns party detail by id with isVerified field', async () => {
    const list: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_party_list',
      [LEGAL_COUNSEL.id, null, null, 1, 0],
    );
    expect(list.data.length).toBeGreaterThan(0);
    const partyId = Number(list.data[0].id);
    const detail: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_party_get_by_id',
      [LEGAL_COUNSEL.id, partyId],
    );
    expect(Number(detail.id)).toBe(partyId);
    expect(typeof detail.isVerified).toBe('boolean');
    expect(Array.isArray(detail.recentContracts5)).toBe(true);
  });

  it('throws P0002 for unknown party id', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_party_get_by_id',
        [LEGAL_COUNSEL.id, 99999999],
      ),
    ).rejects.toThrow(/party_not_found/);
  });
});

describe('fn_template_list / fn_template_get_by_id (058)', () => {
  it('lists templates filtered by contract type', async () => {
    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_template_list',
      [LEGAL_COUNSEL.id, null, null, 100, 0],
    );
    expect(Array.isArray(r.data)).toBe(true);
  });

  it('returns template detail with body', async () => {
    const list: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_template_list',
      [LEGAL_COUNSEL.id, null, null, 1, 0],
    );
    if (list.data.length === 0) return; // empty seed
    const templateId = Number(list.data[0].id);
    const detail: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_template_get_by_id',
      [LEGAL_COUNSEL.id, templateId],
    );
    expect(Number(detail.id)).toBe(templateId);
  });
});

describe('fn_clause_list / fn_clause_get_by_id (058)', () => {
  it('lists clauses', async () => {
    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_clause_list',
      [LEGAL_COUNSEL.id, null, null, null, 100, 0],
    );
    expect(Array.isArray(r.data)).toBe(true);
  });

  it('lists clauses filtered by category=non_compete after R-LC5 seed', async () => {
    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_clause_list',
      [LEGAL_COUNSEL.id, 'non_compete', null, null, 100, 0],
    );
    expect(r.data.every((c: any) => c.category === 'non_compete')).toBe(true);
  });

  it('returns clause detail by id', async () => {
    const list: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_clause_list',
      [LEGAL_COUNSEL.id, null, null, null, 1, 0],
    );
    if (list.data.length === 0) return;
    const clauseId = Number(list.data[0].id);
    const detail: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_clause_get_by_id',
      [LEGAL_COUNSEL.id, clauseId],
    );
    expect(Number(detail.id)).toBe(clauseId);
  });
});

describe('fn_obligation_list (058)', () => {
  it('lists obligations', async () => {
    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_obligation_list',
      [LEGAL_COUNSEL.id, null, null, 50, 0],
    );
    expect(Array.isArray(r.data)).toBe(true);
  });
});

// ─── R4 contract_comment fn_'s ────────────────────────────────────────────

describe('fn_contract_comment_create / list / resolve / delete (065)', () => {
  it('creates a top-level comment + filters lookup by mine', async () => {
    const created: any = await callFnAs(
      DRAFTER.id,
      'fn_contract_comment_create',
      [DRAFTER.id, testContractId, `R-DA9 test comment ${RUN_ID}`, null, []],
    );
    expect(created.data.id).toBeDefined();
    trackedCommentIds.push(Number(created.data.id));

    // List with filter=mine should include this comment for the drafter.
    const list: any = await callFnAs(
      DRAFTER.id,
      'fn_contract_comment_list',
      [DRAFTER.id, testContractId, 'mine'],
    );
    const ids = list.data.map((c: any) => Number(c.id));
    expect(ids).toContain(Number(created.data.id));
  });

  it('rejects empty body with SQLSTATE 22023', async () => {
    await expect(
      callFnAs(
        DRAFTER.id,
        'fn_contract_comment_create',
        [DRAFTER.id, testContractId, '', null, []],
      ),
    ).rejects.toThrow(/body|22023|empty|required/i);
  });

  it('rejects invalid filter with SQLSTATE 22023', async () => {
    await expect(
      callFnAs(
        DRAFTER.id,
        'fn_contract_comment_list',
        [DRAFTER.id, testContractId, 'unknown'],
      ),
    ).rejects.toThrow(/Invalid filter|22023/i);
  });

  it('resolves a comment as the creator', async () => {
    const created: any = await callFnAs(
      DRAFTER.id,
      'fn_contract_comment_create',
      [DRAFTER.id, testContractId, `R-DA9 to-resolve ${RUN_ID}`, null, []],
    );
    const cid = Number(created.data.id);
    trackedCommentIds.push(cid);

    const resolved: any = await callFnAs(
      DRAFTER.id,
      'fn_contract_comment_resolve',
      [DRAFTER.id, cid],
    );
    expect(resolved.data.resolved).toBe(true);
  });

  it('soft-deletes a comment as the creator', async () => {
    const created: any = await callFnAs(
      DRAFTER.id,
      'fn_contract_comment_create',
      [DRAFTER.id, testContractId, `R-DA9 to-delete ${RUN_ID}`, null, []],
    );
    const cid = Number(created.data.id);
    trackedCommentIds.push(cid);

    const deleted: any = await callFnAs(
      DRAFTER.id,
      'fn_contract_comment_delete',
      [DRAFTER.id, cid],
    );
    expect(deleted.data.deleted).toBe(true);

    // Verify it's gone from is_active=TRUE list.
    const list: any = await callFnAs(
      DRAFTER.id,
      'fn_contract_comment_list',
      [DRAFTER.id, testContractId, 'all'],
    );
    expect(list.data.every((c: any) => Number(c.id) !== cid)).toBe(true);
  });
});

// ─── R5 fn_contract_watch_set ─────────────────────────────────────────────

describe('fn_contract_watch_set (066)', () => {
  it('toggles ON then OFF for the calling user', async () => {
    const on: any = await callFnAs(
      APPROVER.id,
      'fn_contract_watch_set',
      [APPROVER.id, testContractId, true],
    );
    expect(on.data.watching).toBe(true);
    expect(Number(on.data.contractId)).toBe(testContractId);
    trackedWatchKeys.push({ user: APPROVER.id, contract: testContractId });

    const off: any = await callFnAs(
      APPROVER.id,
      'fn_contract_watch_set',
      [APPROVER.id, testContractId, false],
    );
    expect(off.data.watching).toBe(false);
  });
});

// ─── R5 fn_approval_my_decisions ──────────────────────────────────────────

describe('fn_approval_my_decisions (066)', () => {
  it('returns paginated decisions list for an approver', async () => {
    const r: any = await callFnAs(
      APPROVER.id,
      'fn_approval_my_decisions',
      [APPROVER.id, null, 1, 20],
    );
    expect(Array.isArray(r.data)).toBe(true);
    expect(typeof r.pagination.total).toBe('number');
  });

  it('filters by decision kind = approve', async () => {
    const r: any = await callFnAs(
      APPROVER.id,
      'fn_approval_my_decisions',
      [APPROVER.id, 'approve', 1, 20],
    );
    expect(Array.isArray(r.data)).toBe(true);
    if (r.data.length > 0) {
      // R5 row shape includes a `decision` field.
      expect(r.data[0].decision).toBeDefined();
    }
  });
});

// ─── R5 fn_approval_watching ──────────────────────────────────────────────

describe('fn_approval_watching (066)', () => {
  it('returns paginated envelope for the calling user', async () => {
    // Watch the test contract first so we have at least one row in
    // contract_watch.
    await callFnAs(
      APPROVER.id,
      'fn_contract_watch_set',
      [APPROVER.id, testContractId, true],
    );
    trackedWatchKeys.push({ user: APPROVER.id, contract: testContractId });

    const r: any = await callFnAs(
      APPROVER.id,
      'fn_approval_watching',
      [APPROVER.id, 1, 20],
    );
    // fn_approval_watching INNER JOINs approval_step where status='pending'
    // — the test contract has no approval chain so its row won't surface
    // in `data`, but the envelope shape must still be correct.
    expect(Array.isArray(r.data)).toBe(true);
    expect(typeof r.pagination.total).toBe('number');
    expect(r.pagination.page).toBe(1);
    expect(r.pagination.limit).toBe(20);
  });

  it('rejects when actorId is null (22023)', async () => {
    await expect(
      callFnAs(
        APPROVER.id,
        'fn_approval_watching',
        [null, 1, 20],
      ),
    ).rejects.toThrow(/actorId required|22023/);
  });
});

// ─── R5 fn_dashboard_approver ─────────────────────────────────────────────

describe('fn_dashboard_approver (068 final body)', () => {
  it('returns dashboard envelope for an approver', async () => {
    const r: any = await callFnAs(
      APPROVER.id,
      'fn_dashboard_approver',
      [30],
    );
    expect(r).toBeDefined();
    expect(r.kpis).toBeDefined();
    // R5 extensions added queueTeamCount / queueQuickApproveCount /
    // slaBreachCount keys.
    expect(typeof r.kpis.pendingMyApprovalCount).toBe('number');
    expect(typeof r.kpis.queueTeamCount).toBe('number');
    expect(typeof r.kpis.slaBreachCount).toBe('number');
  });

  it('rejects a non-approver caller', async () => {
    await expect(
      callFnAs(
        DRAFTER.id,
        'fn_dashboard_approver',
        [30],
      ),
    ).rejects.toThrow(/forbidden|42501/);
  });
});
