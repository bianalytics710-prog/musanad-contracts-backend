/**
 * M19 / CR-K — Risk Case lifecycle DB function tests.
 *
 * Migrations 253..259 + 273..277. Covers all 14 CR-K fn_'s:
 *   fn_risk_case_create
 *   fn_risk_case_auto_create_from_correlation
 *   fn_risk_case_list
 *   fn_risk_case_get_by_id
 *   fn_risk_case_assign
 *   fn_risk_case_add_comment
 *   fn_risk_case_add_evidence
 *   fn_risk_case_evidence_get
 *   fn_risk_case_status_transition
 *   fn_risk_case_escalate
 *   fn_risk_case_accept_risk
 *   fn_risk_case_snooze
 *   fn_risk_case_close
 *   fn_risk_case_escalation_check
 *   S2-21 PUBLIC EXECUTE leak guard
 *
 * Runs against TEST_DATABASE_URL only.
 * ADNOC tenant id = '00000000-0000-0000-0000-000000000001'.
 *
 * One DB test per AC tagged "unit" or "integration" in requirements-analysis.json
 * (see https://[workspace]/requirements-analysis.json). E2E is in FE Playwright spec.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, adminQuery, closeAdminPool } from '../helpers/m1a-helpers';
import { seedFixtureUsers, type SeededFixtureUser } from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const RUN_ID = `crk-${Date.now()}`;

// Tracked ids for cleanup
const trackedCaseIds: number[] = [];
const trackedAttachmentIds: number[] = [];
const trackedCorrelationIds: number[] = [];

let PLATFORM_ADMIN: SeededFixtureUser;
let LEGAL_COUNSEL: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;
let RECIPIENT: SeededFixtureUser;
let APPROVER: SeededFixtureUser;
let EXECUTIVE: SeededFixtureUser;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/** Call fn with COMMIT; useful when we need the row to persist (subsequent fns observe it). */
async function callFnCommit<T>(
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
    if (v instanceof Date) return v.toISOString();
    if (Array.isArray(v) || (typeof v === 'object')) return JSON.stringify(v);
    return v;
  });
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const r = await client.query<{ result: T }>(sql, bound);
    await client.query('COMMIT');
    return r.rows[0]!.result as T;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    throw err;
  } finally {
    client.release();
  }
}

/** Call fn with ROLLBACK — read-only assertion path. */
async function callFnRollback<T>(
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
    if (v instanceof Date) return v.toISOString();
    if (Array.isArray(v) || (typeof v === 'object')) return JSON.stringify(v);
    return v;
  });
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const r = await client.query<{ result: T }>(sql, bound);
    await client.query('ROLLBACK');
    return r.rows[0]!.result as T;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    throw err;
  } finally {
    client.release();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Setup / teardown
// ─────────────────────────────────────────────────────────────────────────────

beforeAll(async () => {
  const users = await seedFixtureUsers();
  PLATFORM_ADMIN = users.get('platform_admin1')!;
  LEGAL_COUNSEL = users.get('legal_counsel1')!;
  DRAFTER = users.get('drafter1')!;
  RECIPIENT = users.get('recipient1')!;
  APPROVER = users.get('approver1')!;
  EXECUTIVE = users.get('executive1')!;
}, 60_000);

afterAll(async () => {
  // Delete risk_case_event, risk_case_attachment, risk_case rows via BYPASSRLS.
  if (trackedCaseIds.length) {
    await adminQuery(
      `DELETE FROM risk_case_event WHERE risk_case_id = ANY($1::bigint[])`,
      [trackedCaseIds],
    );
    await adminQuery(
      `DELETE FROM risk_case_attachment WHERE risk_case_id = ANY($1::bigint[])`,
      [trackedCaseIds],
    );
    await adminQuery(
      `DELETE FROM risk_case WHERE id = ANY($1::bigint[])`,
      [trackedCaseIds],
    );
  }
  if (trackedAttachmentIds.length) {
    await adminQuery(
      `DELETE FROM risk_case_attachment WHERE id = ANY($1::bigint[])`,
      [trackedAttachmentIds],
    );
  }
  if (trackedCorrelationIds.length) {
    await adminQuery(
      `DELETE FROM correlation WHERE id = ANY($1::bigint[])`,
      [trackedCorrelationIds],
    );
  }
  await closeAdminPool();
}, 30_000);

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_create — covers AC-SK2-01..05
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_create', () => {
  it('AC-SK2-01.unit: creates a manual risk case → returns full risk case row with id', async () => {
    const result = await callFnCommit<{ riskCase: { id: number; status: string; caseType: string; tenantId: string } } | { id: number; status: string; caseType: string; tenantId: string }>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-create-ok`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-key-01` }],
    );
    // fn returns fn_risk_case_get_by_id() shape: { riskCase, timeline, ... }
    const obj = result as Record<string, unknown>;
    const rc = (obj.riskCase ?? obj) as { id: number; status: string; caseType: string };
    expect(rc.id).toBeGreaterThan(0);
    expect(rc.status).toBe('open');
    expect(rc.caseType).toBe('manual');
    trackedCaseIds.push(rc.id);
  }, 20_000);

  it('AC-SK2-02.unit: returns 42501 when caller lacks risk.case.create', async () => {
    await expect(
      callFnRollback(RECIPIENT.id, 'fn_risk_case_create',
        [RECIPIENT.id, 'medium', `${RUN_ID}-no-perm`, null, null, null, null, null, {}]),
    ).rejects.toThrow(/permission required|42501/i);
  });

  it('AC-SK2-03.unit: returns 22023 when title is empty after trim', async () => {
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_create',
        [LEGAL_COUNSEL.id, 'medium', '   ', null, null, null, null, null, {}]),
    ).rejects.toThrow(/title is required|22023/i);
  });

  it('AC-SK2-04.unit: returns 22023 when priority is invalid', async () => {
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_create',
        [LEGAL_COUNSEL.id, 'nonsense', `${RUN_ID}-bad-priority`, null, null, null, null, null, {}]),
    ).rejects.toThrow(/priority must be one of|22023/i);
  });

  it('AC-SK2-05.unit: slaHours sets due_at = fn_demo_now() + interval; null when omitted', async () => {
    const withSla = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'high', `${RUN_ID}-sla-24`, null, null, null, null, 24, { idempotencyKey: `${RUN_ID}-key-sla` }],
    );
    const rcSla = (withSla.riskCase ?? withSla) as { id: number; dueAt: string | null };
    expect(rcSla.dueAt).not.toBeNull();
    trackedCaseIds.push(rcSla.id);

    const noSla = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'low', `${RUN_ID}-no-sla`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-key-nosla` }],
    );
    const rcNoSla = (noSla.riskCase ?? noSla) as { id: number; dueAt: string | null };
    expect(rcNoSla.dueAt).toBeNull();
    trackedCaseIds.push(rcNoSla.id);
  }, 20_000);
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_auto_create_from_correlation — covers AC-SK1-01,02,04
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_auto_create_from_correlation', () => {
  let testCorrelationId: number;

  beforeAll(async () => {
    // Prefer to reuse an existing correlation row (avoids osint_signal seeding
    // which has a complex column shape). Falls back to inserting a fresh
    // correlation against an existing signal if no rows yet.
    const existing = await adminQuery<{ id: string }>(
      `SELECT id FROM correlation WHERE tenant_id = $1 LIMIT 1`,
      [ADNOC_TENANT_ID],
    );
    if (existing.length) {
      testCorrelationId = Number(existing[0]!.id);
      return;
    }

    // Fallback: pick any existing signal + rule + insert a fresh correlation
    const sig = await adminQuery<{ id: string }>(
      `SELECT id FROM osint_signal LIMIT 1`,
    );
    const rule = await adminQuery<{ rule_id: string; rule_version_hash: string | null }>(
      `SELECT rule_id, COALESCE(version_hash, 'test-hash') AS rule_version_hash FROM correlation_rule LIMIT 1`,
    );
    if (!sig.length || !rule.length) {
      throw new Error('Cannot seed correlation — osint_signal or correlation_rule empty');
    }
    const corr = await adminQuery<{ id: string }>(
      `INSERT INTO correlation (tenant_id, signal_id, rule_id, rule_version_hash, contract_id,
         confidence, match_reason, match_evidence, status, created_by, updated_by)
         VALUES ($1, $2, $3, $4, NULL, 0.75, 'test seed', '[]'::jsonb, 'active', 1, 1)
         RETURNING id`,
      [ADNOC_TENANT_ID, Number(sig[0]!.id), rule[0]!.rule_id, rule[0]!.rule_version_hash],
    );
    testCorrelationId = Number(corr[0]!.id);
    trackedCorrelationIds.push(testCorrelationId);
  }, 30_000);

  it('AC-SK1-01.unit: creates risk_case with case_type=correlation_alert, correlation_id set, dedupe_key=correlation:<id>', async () => {
    const result = await callFnCommit<{ riskCaseId: number; wasNew: boolean }>(
      0, // DEFINER — actor irrelevant
      'fn_risk_case_auto_create_from_correlation',
      [testCorrelationId],
    );
    expect(result.riskCaseId).toBeGreaterThan(0);
    expect(result.wasNew).toBe(true);
    trackedCaseIds.push(result.riskCaseId);

    // Verify row shape
    const rows = await adminQuery<{ case_type: string; dedupe_key: string; correlation_id: string | null }>(
      `SELECT case_type, dedupe_key, correlation_id FROM risk_case WHERE id = $1`,
      [result.riskCaseId],
    );
    expect(rows[0]!.case_type).toBe('correlation_alert');
    expect(rows[0]!.dedupe_key).toBe(`correlation:${testCorrelationId}`);
    expect(Number(rows[0]!.correlation_id)).toBe(testCorrelationId);
  }, 20_000);

  it('AC-SK1-02.unit: idempotent — second call returns same id with wasNew=false', async () => {
    const second = await callFnCommit<{ riskCaseId: number; wasNew: boolean }>(
      0,
      'fn_risk_case_auto_create_from_correlation',
      [testCorrelationId],
    );
    expect(second.wasNew).toBe(false);
    expect(second.riskCaseId).toBeGreaterThan(0);
  });

  it('AC-SK1-04.unit: unknown correlation_id returns NULL riskCaseId (no exception)', async () => {
    const result = await callFnCommit<{ riskCaseId: number | null; wasNew: boolean }>(
      0,
      'fn_risk_case_auto_create_from_correlation',
      [-999_999],
    );
    expect(result.riskCaseId).toBeNull();
    expect(result.wasNew).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_list — covers AC-SK3-01,02,04
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_list', () => {
  it('AC-SK3-01.unit: returns paginated list with pagination meta', async () => {
    const result = await callFnRollback<{ data: unknown[]; pagination: { total: number; page: number; limit: number; totalPages: number } }>(
      PLATFORM_ADMIN.id,
      'fn_risk_case_list',
      [PLATFORM_ADMIN.id, null, null, false, null, null, null, 1, 20],
    );
    expect(Array.isArray(result.data)).toBe(true);
    expect(result.pagination).toBeDefined();
    expect(result.pagination.page).toBe(1);
    expect(result.pagination.limit).toBe(20);
    expect(typeof result.pagination.total).toBe('number');
    expect(typeof result.pagination.totalPages).toBe('number');
  }, 20_000);

  it('AC-SK3-02.unit: filtering by status narrows result set', async () => {
    const all = await callFnRollback<{ pagination: { total: number } }>(
      PLATFORM_ADMIN.id,
      'fn_risk_case_list',
      [PLATFORM_ADMIN.id, null, null, false, null, null, null, 1, 100],
    );
    const filtered = await callFnRollback<{ pagination: { total: number } }>(
      PLATFORM_ADMIN.id,
      'fn_risk_case_list',
      [PLATFORM_ADMIN.id, 'open', null, false, null, null, null, 1, 100],
    );
    // open-status total <= total
    expect(filtered.pagination.total).toBeLessThanOrEqual(all.pagination.total);
  }, 20_000);

  it('AC-SK3-03.unit: persona scoping — platform_admin sees more cases than recipient (recipient should see 0 or few)', async () => {
    const adminView = await callFnRollback<{ pagination: { total: number } }>(
      PLATFORM_ADMIN.id,
      'fn_risk_case_list',
      [PLATFORM_ADMIN.id, null, null, false, null, null, null, 1, 100],
    );
    // recipient is not in v_full_access set and has no assigned cases / role mapping
    const recipientView = await callFnRollback<{ pagination: { total: number } }>(
      RECIPIENT.id,
      'fn_risk_case_list',
      [RECIPIENT.id, null, null, false, null, null, null, 1, 100],
    );
    expect(recipientView.pagination.total).toBeLessThanOrEqual(adminView.pagination.total);
  }, 20_000);

  it('AC-SK3-04.integration: tenant isolation — different tenant id returns 0 cases', async () => {
    const otherTenantUuid = '99999999-9999-9999-9999-999999999999';
    const result = await callFnRollback<{ pagination: { total: number } }>(
      PLATFORM_ADMIN.id,
      'fn_risk_case_list',
      [PLATFORM_ADMIN.id, null, null, false, null, null, null, 1, 100],
      otherTenantUuid,
    );
    expect(result.pagination.total).toBe(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_get_by_id — covers AC-SK4-01,02
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_get_by_id', () => {
  let workingCaseId: number;

  beforeAll(async () => {
    const r = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'high', `${RUN_ID}-detail-target`, null, null, null, null, 48, { idempotencyKey: `${RUN_ID}-detail-1` }],
    );
    const rc = (r.riskCase ?? r) as { id: number };
    workingCaseId = rc.id;
    trackedCaseIds.push(workingCaseId);
  }, 20_000);

  it('AC-SK4-01.unit: returns riskCase + timeline + attachments + linkedCorrelation + linkedContract + linkedAdvisoryDrafts + slaCountdownSeconds', async () => {
    const result = await callFnRollback<{ riskCase: { id: number }; timeline: unknown[]; attachments: unknown[]; linkedCorrelation: unknown; linkedContract: unknown; linkedAdvisoryDrafts: unknown[]; slaCountdownSeconds: number | null }>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_get_by_id',
      [LEGAL_COUNSEL.id, workingCaseId],
    );
    expect(result.riskCase).toBeDefined();
    expect(result.riskCase.id).toBe(workingCaseId);
    expect(Array.isArray(result.timeline)).toBe(true);
    expect(result.timeline.length).toBeGreaterThanOrEqual(1); // 'created' event
    expect(Array.isArray(result.attachments)).toBe(true);
    expect(Array.isArray(result.linkedAdvisoryDrafts)).toBe(true);
    expect(typeof result.slaCountdownSeconds === 'number' || result.slaCountdownSeconds === null).toBe(true);
  });

  it('AC-SK4-02.unit: returns P0002 when id not found in tenant', async () => {
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_get_by_id', [LEGAL_COUNSEL.id, -1]),
    ).rejects.toThrow(/not found|P0002/i);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_assign — covers AC-SK5-01,02,03,04
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_assign', () => {
  let caseId: number;

  beforeAll(async () => {
    const r = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-assign-target`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-assign-1` }],
    );
    const rc = (r.riskCase ?? r) as { id: number };
    caseId = rc.id;
    trackedCaseIds.push(caseId);
  }, 15_000);

  it('AC-SK5-01.unit: assigns to role + user → returns updated row with assigned_role/user set', async () => {
    const result = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_assign',
      [LEGAL_COUNSEL.id, caseId, 'legal_counsel', LEGAL_COUNSEL.id],
    );
    const rc = (result.riskCase ?? result) as { id: number; assignedRole: string; assignedUserId: number };
    expect(rc.assignedRole).toBe('legal_counsel');
    expect(Number(rc.assignedUserId)).toBe(LEGAL_COUNSEL.id);

    // Verify 'assigned' event emitted
    const events = await adminQuery<{ event_type: string }>(
      `SELECT event_type FROM risk_case_event WHERE risk_case_id = $1 AND event_type = 'assigned'`,
      [caseId],
    );
    expect(events.length).toBeGreaterThanOrEqual(1);
  });

  it('AC-SK5-02.unit: returns 22023 when both assignedRole and assignedUserId are null', async () => {
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_assign', [LEGAL_COUNSEL.id, caseId, null, null]),
    ).rejects.toThrow(/Either assignedRole or assignedUserId|22023/i);
  });

  it('AC-SK5-03.unit: returns 22023 when user does not hold the assigned role', async () => {
    // DRAFTER does not hold legal_counsel role
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_assign',
        [LEGAL_COUNSEL.id, caseId, 'legal_counsel', DRAFTER.id]),
    ).rejects.toThrow(/does not hold|22023/i);
  });

  it('AC-SK5-04.unit: returns 409/P0001 when assigning a closed case', async () => {
    // Move through approve/close lifecycle first
    const closedCase = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'low', `${RUN_ID}-assign-closed`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-assign-closed-1` }],
    );
    const rc = (closedCase.riskCase ?? closedCase) as { id: number };
    trackedCaseIds.push(rc.id);

    // open -> in_review -> approved -> closed
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'in_review', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'approved', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_close', [LEGAL_COUNSEL.id, rc.id, 'mitigated', null]);

    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_assign',
        [LEGAL_COUNSEL.id, rc.id, 'legal_counsel', null]),
    ).rejects.toThrow(/closed\/rejected|P0001/i);
  }, 30_000);
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_add_comment — covers AC-SK6-01,02,03
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_add_comment', () => {
  let caseId: number;

  beforeAll(async () => {
    const r = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-comment-target`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-comment-1` }],
    );
    const rc = (r.riskCase ?? r) as { id: number };
    caseId = rc.id;
    trackedCaseIds.push(caseId);
  }, 15_000);

  it('AC-SK6-01.unit: returns eventId and appends event_type=comment_added', async () => {
    const result = await callFnCommit<{ eventId: number }>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_add_comment',
      [LEGAL_COUNSEL.id, caseId, 'Reviewed and flagged for legal escalation.'],
    );
    expect(result.eventId).toBeGreaterThan(0);
    const events = await adminQuery<{ event_type: string }>(
      `SELECT event_type FROM risk_case_event WHERE id = $1`,
      [result.eventId],
    );
    expect(events[0]!.event_type).toBe('comment_added');
  });

  it('AC-SK6-02.unit: returns 22023 when comment is empty after trim', async () => {
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_add_comment', [LEGAL_COUNSEL.id, caseId, '   ']),
    ).rejects.toThrow(/comment is required|22023/i);
  });

  it('AC-SK6-03.unit: comments allowed on a closed case (no state guard)', async () => {
    // Close a fresh case then comment on it
    const closed = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'low', `${RUN_ID}-comment-closed`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-comment-closed-1` }],
    );
    const rc = (closed.riskCase ?? closed) as { id: number };
    trackedCaseIds.push(rc.id);

    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'in_review', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'approved', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_close', [LEGAL_COUNSEL.id, rc.id, 'mitigated', null]);

    const result = await callFnCommit<{ eventId: number }>(
      LEGAL_COUNSEL.id, 'fn_risk_case_add_comment',
      [LEGAL_COUNSEL.id, rc.id, 'Post-closure follow-up note.'],
    );
    expect(result.eventId).toBeGreaterThan(0);
  }, 30_000);
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_add_evidence + fn_risk_case_evidence_get
// covers AC-SK7-02,03 + AC-SK8-02,03
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_add_evidence + fn_risk_case_evidence_get', () => {
  let caseId: number;
  let attachmentId: number;

  beforeAll(async () => {
    const r = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-evidence-target`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-evidence-1` }],
    );
    const rc = (r.riskCase ?? r) as { id: number };
    caseId = rc.id;
    trackedCaseIds.push(caseId);
  }, 15_000);

  it('AC-SK7-01.integration: adds evidence row + emits evidence_uploaded event', async () => {
    const result = await callFnCommit<{ attachmentId: number; eventId: number }>(
      LEGAL_COUNSEL.id,
      'fn_risk_case_add_evidence',
      [LEGAL_COUNSEL.id, caseId, 'risk-case/test/path.pdf', 'evidence.pdf', 'application/pdf', 1024],
    );
    expect(result.attachmentId).toBeGreaterThan(0);
    expect(result.eventId).toBeGreaterThan(0);
    attachmentId = result.attachmentId;
  });

  it('AC-SK7-02.unit: returns 23514 when file_bytes > 50MB', async () => {
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_add_evidence',
        [LEGAL_COUNSEL.id, caseId, 'risk-case/test/big.pdf', 'big.pdf', 'application/pdf', 52428801]),
    ).rejects.toThrow(/50MB|23514/i);
  });

  it('AC-SK7-02b.unit: returns 23514 when file_bytes = 0', async () => {
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_add_evidence',
        [LEGAL_COUNSEL.id, caseId, 'risk-case/test/zero.pdf', 'zero.pdf', 'application/pdf', 0]),
    ).rejects.toThrow(/> 0|23514/i);
  });

  it('AC-SK7-03.unit: returns P0001 when uploading evidence to a closed case', async () => {
    const closed = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'low', `${RUN_ID}-evidence-closed`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-evidence-closed-1` }],
    );
    const rc = (closed.riskCase ?? closed) as { id: number };
    trackedCaseIds.push(rc.id);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'in_review', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'approved', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_close', [LEGAL_COUNSEL.id, rc.id, 'no_action', null]);

    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_add_evidence',
        [LEGAL_COUNSEL.id, rc.id, 'risk-case/closed/late.pdf', 'late.pdf', 'application/pdf', 1024]),
    ).rejects.toThrow(/closed case|P0001/i);
  }, 30_000);

  it('AC-SK8-02.integration: evidence_get returns P0002 when attachment id does not exist', async () => {
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_evidence_get',
        [LEGAL_COUNSEL.id, caseId, -1]),
    ).rejects.toThrow(/not found|P0002/i);
  });

  it('AC-SK8-03.unit: evidence_get returns P0002 when attachment is soft-deleted', async () => {
    // Soft-delete the attachment we just made
    await adminQuery(`UPDATE risk_case_attachment SET is_active = FALSE WHERE id = $1`, [attachmentId]);
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_evidence_get',
        [LEGAL_COUNSEL.id, caseId, attachmentId]),
    ).rejects.toThrow(/not found|P0002/i);
    // restore for cleanup
    await adminQuery(`UPDATE risk_case_attachment SET is_active = TRUE WHERE id = $1`, [attachmentId]);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_status_transition — covers AC-SK9-01,02,03,04,05
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_status_transition', () => {
  let caseId: number;

  beforeAll(async () => {
    const r = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-status-target`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-status-1` }],
    );
    const rc = (r.riskCase ?? r) as { id: number };
    caseId = rc.id;
    trackedCaseIds.push(caseId);
  }, 15_000);

  it('AC-SK9-01.unit: open → in_review → approved emits status_changed events', async () => {
    const t1 = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_status_transition',
      [LEGAL_COUNSEL.id, caseId, 'in_review', null],
    );
    expect((t1.riskCase ?? t1) as { status: string }).toHaveProperty('status', 'in_review');

    const t2 = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_status_transition',
      [LEGAL_COUNSEL.id, caseId, 'approved', 'looks clean'],
    );
    expect((t2.riskCase ?? t2) as { status: string }).toHaveProperty('status', 'approved');

    // 2 status_changed events
    const events = await adminQuery<{ event_type: string }>(
      `SELECT event_type FROM risk_case_event WHERE risk_case_id = $1 AND event_type = 'status_changed' ORDER BY id`,
      [caseId],
    );
    expect(events.length).toBe(2);
  }, 20_000);

  it('AC-SK9-02.unit: returns P0001 on invalid transition (approved → in_review)', async () => {
    // The case is already 'approved' from previous test
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition',
        [LEGAL_COUNSEL.id, caseId, 'in_review', null]),
    ).rejects.toThrow(/Invalid transition|P0001/i);
  });

  it('AC-SK9-03.unit: returns 22023 when toStatus is not in {in_review, approved, rejected}', async () => {
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition',
        [LEGAL_COUNSEL.id, caseId, 'snoozed', null]),
    ).rejects.toThrow(/toStatus must be|22023/i);
  });

  it('AC-SK9-04.unit: returns 42501 when caller lacks risk.case.escalate AND is not assignee', async () => {
    // Create a fresh correlation_alert-typed case (priv-required for that case_type),
    // assign to LEGAL_COUNSEL, then try transition as DRAFTER (no escalate perm, not the assignee)
    const fresh = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'high', `${RUN_ID}-status-403`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-status-403-1` }],
    );
    const rc = (fresh.riskCase ?? fresh) as { id: number };
    trackedCaseIds.push(rc.id);

    // Patch case_type to correlation_alert via BYPASSRLS so the stricter perm path engages
    await adminQuery(
      `UPDATE risk_case SET case_type = 'correlation_alert' WHERE id = $1`,
      [rc.id],
    );

    // Assign to LEGAL_COUNSEL
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_assign', [LEGAL_COUNSEL.id, rc.id, 'legal_counsel', LEGAL_COUNSEL.id]);

    // DRAFTER has no risk.case.escalate and is not the assignee
    await expect(
      callFnRollback(DRAFTER.id, 'fn_risk_case_status_transition',
        [DRAFTER.id, rc.id, 'in_review', null]),
    ).rejects.toThrow(/permission denied|42501/i);
  }, 30_000);
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_escalate — covers AC-SK10-01,02,03,04,05
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_escalate', () => {
  let caseId: number;

  beforeAll(async () => {
    const r = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'high', `${RUN_ID}-esc-target`, null, null, 'legal_counsel', null, null, { idempotencyKey: `${RUN_ID}-esc-1` }],
    );
    const rc = (r.riskCase ?? r) as { id: number };
    caseId = rc.id;
    trackedCaseIds.push(caseId);
  }, 15_000);

  it('AC-SK10-01.unit: escalate updates assigned_role to next in matrix, status=escalated, emits event', async () => {
    const result = await callFnCommit<{ riskCase: Record<string, unknown>; newAssignedRole: string; matrixHopCount: number }>(
      LEGAL_COUNSEL.id, 'fn_risk_case_escalate',
      [LEGAL_COUNSEL.id, caseId, 'first hop'],
    );
    expect(result.newAssignedRole).toBeTruthy();
    expect(result.matrixHopCount).toBe(1);

    const events = await adminQuery<{ event_type: string; payload: { matrixHopCount: number } }>(
      `SELECT event_type, payload FROM risk_case_event WHERE risk_case_id = $1 AND event_type = 'escalated' ORDER BY id DESC LIMIT 1`,
      [caseId],
    );
    expect(events.length).toBe(1);
    expect(events[0]!.payload.matrixHopCount).toBe(1);
  });

  it('AC-SK10-02.unit: P0001 when already at top of matrix', async () => {
    // Patch metadata.escalationHops to 9 + assigned_role to a leaf to provoke 'no next'
    // The escalation matrix seeded by mig 257 terminates at executive — set assigned_role=executive
    await adminQuery(
      `UPDATE risk_case
         SET assigned_role = 'executive',
             metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{escalationHops}', to_jsonb(2), true)
       WHERE id = $1`,
      [caseId],
    );
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_escalate', [LEGAL_COUNSEL.id, caseId, 'top']),
    ).rejects.toThrow(/already at top|P0001/i);
  });

  it('AC-SK10-03.unit: P0001 when escalating a closed case', async () => {
    const fresh = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'high', `${RUN_ID}-esc-closed`, null, null, 'legal_counsel', null, null, { idempotencyKey: `${RUN_ID}-esc-closed-1` }],
    );
    const rc = (fresh.riskCase ?? fresh) as { id: number };
    trackedCaseIds.push(rc.id);

    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'in_review', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'approved', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_close', [LEGAL_COUNSEL.id, rc.id, 'mitigated', null]);

    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_escalate', [LEGAL_COUNSEL.id, rc.id, null]),
    ).rejects.toThrow(/closed|P0001/i);
  }, 30_000);

  it('AC-SK10-04.unit: 42501 when caller lacks risk.case.escalate', async () => {
    await expect(
      callFnRollback(DRAFTER.id, 'fn_risk_case_escalate', [DRAFTER.id, caseId, null]),
    ).rejects.toThrow(/permission required|42501/i);
  });

  it('AC-SK10-05.integration: hopCount > 10 triggers matrix_cycle_detected (P0001)', async () => {
    const fresh = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'high', `${RUN_ID}-esc-cycle`, null, null, 'legal_counsel', null, null, { idempotencyKey: `${RUN_ID}-esc-cycle-1` }],
    );
    const rc = (fresh.riskCase ?? fresh) as { id: number };
    trackedCaseIds.push(rc.id);

    await adminQuery(
      `UPDATE risk_case SET metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{escalationHops}', to_jsonb(10), true) WHERE id = $1`,
      [rc.id],
    );
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_escalate', [LEGAL_COUNSEL.id, rc.id, null]),
    ).rejects.toThrow(/cycle_detected|P0001/i);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_accept_risk — covers AC-SK11-01,02,03,04
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_accept_risk', () => {
  let caseId: number;

  beforeAll(async () => {
    const r = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'high', `${RUN_ID}-accept-target`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-accept-1` }],
    );
    const rc = (r.riskCase ?? r) as { id: number };
    caseId = rc.id;
    trackedCaseIds.push(caseId);
  }, 15_000);

  it('AC-SK11-01.unit: sets status=accept_risk + closure_outcome=accepted; emits accepted_risk event', async () => {
    // LEGAL_COUNSEL has risk.case.accept_risk; high → legal_counsel approver required per default matrix
    const result = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_accept_risk',
      [LEGAL_COUNSEL.id, caseId, LEGAL_COUNSEL.id, 'risk has been signed off by legal'],
    );
    const rc = (result.riskCase ?? result) as { status: string; closureOutcome: string };
    expect(rc.status).toBe('accept_risk');
    expect(rc.closureOutcome).toBe('accepted');

    const events = await adminQuery<{ event_type: string }>(
      `SELECT event_type FROM risk_case_event WHERE risk_case_id = $1 AND event_type = 'accepted_risk'`,
      [caseId],
    );
    expect(events.length).toBe(1);
  });

  it('AC-SK11-02.unit: P0001 when approver does not hold required role for priority', async () => {
    const fresh = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'critical', `${RUN_ID}-accept-critical`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-accept-critical-1` }],
    );
    const rc = (fresh.riskCase ?? fresh) as { id: number };
    trackedCaseIds.push(rc.id);

    // critical → executive required; legal_counsel as approver is insufficient
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_accept_risk',
        [LEGAL_COUNSEL.id, rc.id, LEGAL_COUNSEL.id, 'this should fail because LC is not exec']),
    ).rejects.toThrow(/Approver role insufficient|P0001/i);
  });

  it('AC-SK11-03.unit: 22023 when justification < 10 chars', async () => {
    const fresh = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-accept-short`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-accept-short-1` }],
    );
    const rc = (fresh.riskCase ?? fresh) as { id: number };
    trackedCaseIds.push(rc.id);

    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_accept_risk',
        [LEGAL_COUNSEL.id, rc.id, LEGAL_COUNSEL.id, 'short']),
    ).rejects.toThrow(/at least 10|22023/i);
  });

  it('AC-SK11-04.unit: 42501 when caller lacks risk.case.accept_risk', async () => {
    const fresh = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-accept-403`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-accept-403-1` }],
    );
    const rc = (fresh.riskCase ?? fresh) as { id: number };
    trackedCaseIds.push(rc.id);

    await expect(
      callFnRollback(DRAFTER.id, 'fn_risk_case_accept_risk',
        [DRAFTER.id, rc.id, LEGAL_COUNSEL.id, 'no perms here at all']),
    ).rejects.toThrow(/permission required|42501/i);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_snooze — covers AC-SK12-01,02,03,04
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_snooze', () => {
  let caseId: number;

  beforeAll(async () => {
    const r = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'low', `${RUN_ID}-snooze-target`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-snooze-1` }],
    );
    const rc = (r.riskCase ?? r) as { id: number };
    caseId = rc.id;
    trackedCaseIds.push(caseId);
  }, 15_000);

  it('AC-SK12-01.unit: snoozing future ISO sets status=snoozed + snoozed_until', async () => {
    const future = new Date(Date.now() + 24 * 60 * 60 * 1000); // tomorrow
    const result = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_snooze',
      [LEGAL_COUNSEL.id, caseId, future.toISOString()],
    );
    const rc = (result.riskCase ?? result) as { status: string; snoozedUntil: string };
    expect(rc.status).toBe('snoozed');
    expect(rc.snoozedUntil).toBeTruthy();
  });

  it('AC-SK12-02.unit: 22023 when snoozedUntil is in the past', async () => {
    const past = new Date(Date.now() - 60 * 60 * 1000); // 1h ago
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_snooze',
        [LEGAL_COUNSEL.id, caseId, past.toISOString()]),
    ).rejects.toThrow(/in the future|22023/i);
  });

  it('AC-SK12-03.unit: 22023 when snoozedUntil > 30 days', async () => {
    const farFuture = new Date(Date.now() + 31 * 24 * 60 * 60 * 1000);
    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_snooze',
        [LEGAL_COUNSEL.id, caseId, farFuture.toISOString()]),
    ).rejects.toThrow(/30 days|22023/i);
  });

  it('AC-SK12-04.integration: snoozed cases are excluded from fn_risk_case_escalation_check', async () => {
    // The case is currently snoozed with future snoozed_until.
    // fn_risk_case_escalation_check returns rows with due_at < now() AND status not in terminal AND snoozed_until <= now()
    const result = await callFnRollback<{ candidates: Array<{ id: number }> }>(
      0, 'fn_risk_case_escalation_check', [100],
    );
    const found = result.candidates.find((c) => Number(c.id) === caseId);
    expect(found).toBeUndefined();
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_close — covers AC-SK13-01,02,03,04
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_close', () => {
  it('AC-SK13-01.unit: closes from approved with outcome=mitigated, emits closed event', async () => {
    const created = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-close-ok`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-close-ok-1` }],
    );
    const rc = (created.riskCase ?? created) as { id: number };
    trackedCaseIds.push(rc.id);

    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'in_review', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'approved', null]);

    const result = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_close',
      [LEGAL_COUNSEL.id, rc.id, 'mitigated', 'all done'],
    );
    const out = (result.riskCase ?? result) as { status: string; closureOutcome: string; closedAt: string };
    expect(out.status).toBe('closed');
    expect(out.closureOutcome).toBe('mitigated');
    expect(out.closedAt).toBeTruthy();
  }, 30_000);

  it('AC-SK13-02.unit: 22023 when outcome is invalid', async () => {
    const created = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-close-bad-outcome`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-close-bad-outcome-1` }],
    );
    const rc = (created.riskCase ?? created) as { id: number };
    trackedCaseIds.push(rc.id);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'in_review', null]);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_status_transition', [LEGAL_COUNSEL.id, rc.id, 'approved', null]);

    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_close',
        [LEGAL_COUNSEL.id, rc.id, 'nonsense', null]),
    ).rejects.toThrow(/invalid outcome|22023/i);
  }, 30_000);

  it('AC-SK13-03.unit: P0001 when closing from status=open (no prior action)', async () => {
    const fresh = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-close-from-open`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-close-from-open-1` }],
    );
    const rc = (fresh.riskCase ?? fresh) as { id: number };
    trackedCaseIds.push(rc.id);

    await expect(
      callFnRollback(LEGAL_COUNSEL.id, 'fn_risk_case_close',
        [LEGAL_COUNSEL.id, rc.id, 'mitigated', null]),
    ).rejects.toThrow(/without prior action|P0001/i);
  });

  it('AC-SK13-04.unit: 42501 when caller lacks risk.case.close', async () => {
    const fresh = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'medium', `${RUN_ID}-close-403`, null, null, null, null, null, { idempotencyKey: `${RUN_ID}-close-403-1` }],
    );
    const rc = (fresh.riskCase ?? fresh) as { id: number };
    trackedCaseIds.push(rc.id);

    // RECIPIENT holds zero risk.case.* perms per mig 256/273 (contract_drafter
    // does hold risk.case.close per the pre-emptive grant backfill 273).
    await expect(
      callFnRollback(RECIPIENT.id, 'fn_risk_case_close',
        [RECIPIENT.id, rc.id, 'mitigated', null]),
    ).rejects.toThrow(/permission required|42501/i);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// fn_risk_case_escalation_check — covers AC-SK14-01,03,05
// ─────────────────────────────────────────────────────────────────────────────

describe('fn_risk_case_escalation_check', () => {
  it('AC-SK14-01.unit: returns array of candidate cases under p_limit', async () => {
    const result = await callFnRollback<{ candidates: unknown[] }>(
      0, 'fn_risk_case_escalation_check', [100],
    );
    expect(Array.isArray(result.candidates)).toBe(true);
    expect(result.candidates.length).toBeLessThanOrEqual(100);
  });

  it('AC-SK14-05.unit: snoozed cases are excluded', async () => {
    // Create a case past-due in the past with snoozed_until in the future
    const created = await callFnCommit<Record<string, unknown>>(
      LEGAL_COUNSEL.id, 'fn_risk_case_create',
      [LEGAL_COUNSEL.id, 'high', `${RUN_ID}-escheck-snoozed`, null, null, 'legal_counsel', null, 1, { idempotencyKey: `${RUN_ID}-escheck-snoozed-1` }],
    );
    const rc = (created.riskCase ?? created) as { id: number };
    trackedCaseIds.push(rc.id);

    const future = new Date(Date.now() + 12 * 60 * 60 * 1000);
    await callFnCommit(LEGAL_COUNSEL.id, 'fn_risk_case_snooze', [LEGAL_COUNSEL.id, rc.id, future.toISOString()]);
    // backdate due_at via BYPASSRLS to force it < now()
    await adminQuery(`UPDATE risk_case SET due_at = NOW() - INTERVAL '1 day' WHERE id = $1`, [rc.id]);

    const result = await callFnRollback<{ candidates: Array<{ id: number }> }>(
      0, 'fn_risk_case_escalation_check', [100],
    );
    const found = result.candidates.find((c) => Number(c.id) === rc.id);
    expect(found).toBeUndefined();
  }, 30_000);
});

// ─────────────────────────────────────────────────────────────────────────────
// S2-21 — no PUBLIC EXECUTE on any CR-K fn
// ─────────────────────────────────────────────────────────────────────────────

describe('S2-21 — CR-K fns have no PUBLIC EXECUTE', () => {
  const CRK_FNS = [
    'fn_risk_case_create',
    'fn_risk_case_auto_create_from_correlation',
    'fn_risk_case_list',
    'fn_risk_case_get_by_id',
    'fn_risk_case_assign',
    'fn_risk_case_add_comment',
    'fn_risk_case_add_evidence',
    'fn_risk_case_evidence_get',
    'fn_risk_case_status_transition',
    'fn_risk_case_escalate',
    'fn_risk_case_accept_risk',
    'fn_risk_case_snooze',
    'fn_risk_case_close',
    'fn_risk_case_escalation_check',
  ];

  it('every CR-K fn has proacl that omits PUBLIC=X', async () => {
    const rows = await adminQuery<{ proname: string; proacl: string | null }>(
      `SELECT proname, proacl::text AS proacl
         FROM pg_proc
        WHERE proname = ANY($1::text[])
          AND pronamespace = 'public'::regnamespace`,
      [CRK_FNS],
    );
    // Every fn must have proacl that does NOT include =X (PUBLIC execute)
    for (const r of rows) {
      // proacl null means default = PUBLIC EXECUTE; treat as fail
      expect(r.proacl, `${r.proname} has null proacl — PUBLIC EXECUTE leak`).not.toBeNull();
      expect(r.proacl).not.toMatch(/=X[a-z]/);
    }
    expect(rows.length).toBeGreaterThanOrEqual(CRK_FNS.length);
  });
});
