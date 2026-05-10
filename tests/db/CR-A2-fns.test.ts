/**
 * M8 — CR-A2 — Database function tests for the 4 internal-signal fn_'s.
 *
 *   - fn_internal_signal_kind_list   (INVOKER STABLE; permission internal_signal.read)
 *   - fn_internal_signal_ingest      (DEFINER, REVOKE-only; system-only)
 *   - fn_internal_signal_resolve     (INVOKER; permission internal_signal.resolve + Q-DA3 hardcoded role allowlist)
 *   - fn_internal_signal_list        (INVOKER STABLE; permission internal_signal.read)
 *
 * Each test runs against the Neon `test` branch (TEST_DATABASE_URL) with
 * the ADNOC tenant GUC + actor GUC set per call. Permission gates are
 * exercised via fixture users (legal_counsel / drafter / executive /
 * platform_admin). Patch round 113 already resolved DEFECT-1 in
 * fn_internal_signal_resolve (user_role junction → "user".role_id single FK);
 * tests assert the post-113 behaviour.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, adminQuery } from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const OTHER_TENANT_ID = '00000000-0000-0000-0000-0000000000ff'; // synthetic — used only for AC-S8-02 negative scope test

const RUN_ID = `cra2-${Date.now()}`;
const trackedSignalIds: number[] = [];

let PLATFORM_ADMIN: SeededFixtureUser;
let LEGAL_COUNSEL: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;
let EXECUTIVE: SeededFixtureUser;

/**
 * Call a fn_ with both `app.current_user_id` AND `app.current_tenant_id`
 * GUCs set. Mirrors what the BE controller layer does for every M7/M8 call.
 *
 * Borrowed verbatim from CR-A-fns.test.ts.
 */
const callFnAsWithTenant = async <T>(
  actorId: number | null,
  tenantId: string | null,
  fnName: string,
  args: ReadonlyArray<unknown>,
): Promise<T> => {
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
    if (typeof v === 'object' && !(v instanceof Date)) return JSON.stringify(v);
    return v;
  });
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    if (actorId !== null) {
      await client.query("SELECT set_config('app.current_user_id', $1, true)", [
        String(actorId),
      ]);
    }
    if (tenantId !== null) {
      await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [
        tenantId,
      ]);
    }
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

beforeAll(async () => {
  await seedFixtureUsers();
  PLATFORM_ADMIN = getFixture('platform_admin1');
  LEGAL_COUNSEL = getFixture('legal_counsel1');
  DRAFTER = getFixture('drafter1');
  EXECUTIVE = getFixture('executive1');

  // Sanity — test branch must be at version 113 for these tests to mean
  // anything (113 is the resolve-fix patch). If less, tests would be
  // exercising stale schema; surface clearly.
  const v = await adminQuery<{ version: number }>(
    `SELECT MAX(version)::int AS version FROM schema_migrations`,
  );
  expect(v[0]!.version).toBeGreaterThanOrEqual(113);
});

afterAll(async () => {
  // Hard-delete only the signals this suite created. Seed signals (10
  // demo rows from migration 112) MUST stay — other suites depend on them.
  if (trackedSignalIds.length > 0) {
    await adminQuery(
      `DELETE FROM osint_signal WHERE id = ANY($1::BIGINT[])`,
      [trackedSignalIds],
    );
  }
});

// ============================================================================
// AC-S6-01 / AC-S1-01 / AC-S1-02 — fn_internal_signal_kind_list
// ============================================================================

describe('CR-A2 — fn_internal_signal_kind_list', () => {
  it('AC-S6-01 / AC-S1-01: returns the 8 catalogue rows for ADNOC tenant', async () => {
    const rows: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_kind_list',
      [PLATFORM_ADMIN.id],
    );
    expect(Array.isArray(rows)).toBe(true);
    expect(rows.length).toBe(8);

    const types = rows.map((r: any) => r.signalType).sort();
    expect(types).toEqual([
      'certificate_expiry',
      'ics_incident',
      'icv_status_change',
      'invoice_dispute',
      'milestone_slippage',
      'payment_delay',
      'sla_breach',
      'vendor_incident',
    ]);

    // AC-S1-02: every row has non-null EN + AR display, parameterSchema, severity in enum
    const SEVERITIES = new Set(['informational', 'low', 'medium', 'high', 'critical']);
    for (const row of rows) {
      expect(typeof row.id).toBe('number');
      expect(typeof row.displayName).toBe('string');
      expect(row.displayName.length).toBeGreaterThan(0);
      expect(typeof row.displayNameAr).toBe('string');
      expect(row.displayNameAr.length).toBeGreaterThan(0);
      expect(row.parameterSchema).toBeDefined();
      expect(Array.isArray(row.parameterSchema.required)).toBe(true);
      expect(Array.isArray(row.parameterSchema.optional)).toBe(true);
      expect(SEVERITIES.has(row.defaultSeverity)).toBe(true);
      expect(row.isActive).toBe(true);
    }
  });

  it('AC-S6-05 / permission gate: drafter (no internal_signal.read) raises 42501', async () => {
    await expect(
      callFnAsWithTenant(DRAFTER.id, ADNOC_TENANT_ID, 'fn_internal_signal_kind_list', [
        DRAFTER.id,
      ]),
    ).rejects.toMatchObject({ code: '42501' });
  });
});

// ============================================================================
// AC-S2-01 / AC-S2-02 / AC-S2-03 / AC-S2-04 / AC-S7-* — fn_internal_signal_ingest
// ============================================================================

describe('CR-A2 — fn_internal_signal_ingest', () => {
  // Resolve a real EPC contract id once for this suite. The 112 seed
  // INSERTed contract_number='CRA2-EPC-2026-001' on apply.
  let EPC_CONTRACT_ID: number;

  beforeAll(async () => {
    const rows = await adminQuery<{ id: string }>(
      `SELECT id::text AS id FROM contract WHERE contract_number = 'CRA2-EPC-2026-001'`,
    );
    expect(rows.length).toBe(1);
    EPC_CONTRACT_ID = Number(rows[0]!.id);
  });

  it('AC-S2-01: happy path — milestone_slippage returns inserted=true + signalId + signalKindSubtype', async () => {
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 5).toISOString(); // 5 days ago, unique
    const r: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_ingest',
      [
        {
          signalType: 'milestone_slippage',
          contractId: EPC_CONTRACT_ID,
          milestoneRef: `M-CRA2TEST-${RUN_ID}`,
          observedAt,
          severityCalcInput: { daysSlippage: 11 },
        },
      ],
    );
    expect(r).toBeDefined();
    expect(r.inserted).toBe(true);
    expect(r.dedupHashHit).toBe(false);
    expect(typeof r.signalId).toBe('number');
    expect(r.signalKindSubtype).toBe('milestone_slippage');
    trackedSignalIds.push(r.signalId);

    // Confirm the row landed with kind='internal' + source_id='internal:harness'
    const rows = await adminQuery<{ kind: string; signal_kind_subtype: string; source_id: string }>(
      `SELECT kind, signal_kind_subtype, source_id FROM osint_signal WHERE id = $1`,
      [r.signalId],
    );
    expect(rows[0]!.kind).toBe('internal');
    expect(rows[0]!.signal_kind_subtype).toBe('milestone_slippage');
    expect(rows[0]!.source_id).toBe('internal:harness');
  });

  it('AC-S2-02 / AC-S7-02: re-posting identical payload returns inserted=false + dedupHashHit=true with same signalId', async () => {
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 7).toISOString();
    const payload = {
      signalType: 'milestone_slippage',
      contractId: EPC_CONTRACT_ID,
      milestoneRef: `M-CRA2DEDUP-${RUN_ID}`,
      observedAt,
    };
    const r1: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_ingest',
      [payload],
    );
    expect(r1.inserted).toBe(true);
    trackedSignalIds.push(r1.signalId);

    const r2: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_ingest',
      [payload],
    );
    expect(r2.inserted).toBe(false);
    expect(r2.dedupHashHit).toBe(true);
    expect(r2.signalId).toBe(r1.signalId);

    // Exactly ONE row exists in the table for this dedup_hash.
    const rows = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count FROM osint_signal WHERE id = $1`,
      [r1.signalId],
    );
    expect(rows[0]!.count).toBe('1');
  });

  it('AC-S7-03: same signalType+contract but different observedAt yields a distinct row', async () => {
    const obs1 = new Date(Date.now() - 1000 * 60 * 60 * 24 * 11).toISOString();
    const obs2 = new Date(Date.now() - 1000 * 60 * 60 * 24 * 12).toISOString();
    const r1: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_ingest',
      [{
        signalType: 'milestone_slippage',
        contractId: EPC_CONTRACT_ID,
        milestoneRef: `M-DIFFOBS-${RUN_ID}`,
        observedAt: obs1,
      }],
    );
    const r2: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_ingest',
      [{
        signalType: 'milestone_slippage',
        contractId: EPC_CONTRACT_ID,
        milestoneRef: `M-DIFFOBS-${RUN_ID}`,
        observedAt: obs2,
      }],
    );
    trackedSignalIds.push(r1.signalId, r2.signalId);
    expect(r1.signalId).not.toBe(r2.signalId);
    expect(r1.inserted).toBe(true);
    expect(r2.inserted).toBe(true);
  });

  it('AC-S2-03: unknown signalType raises (with "Unknown internal signal type" message)', async () => {
    const observedAt = new Date().toISOString();
    await expect(
      callFnAsWithTenant(PLATFORM_ADMIN.id, ADNOC_TENANT_ID, 'fn_internal_signal_ingest', [{
        signalType: 'definitely_not_a_real_type',
        contractId: EPC_CONTRACT_ID,
        observedAt,
      }]),
    ).rejects.toMatchObject({
      message: expect.stringMatching(/Unknown internal signal type/i),
    });
  });

  it('AC-S2-04: missing required field per parameter_schema raises with field-name in message', async () => {
    // milestone_slippage requires milestoneRef per internal_signal_kind.parameter_schema.
    const observedAt = new Date().toISOString();
    await expect(
      callFnAsWithTenant(PLATFORM_ADMIN.id, ADNOC_TENANT_ID, 'fn_internal_signal_ingest', [{
        signalType: 'milestone_slippage',
        contractId: EPC_CONTRACT_ID,
        observedAt,
        // milestoneRef intentionally omitted
      }]),
    ).rejects.toMatchObject({
      message: expect.stringMatching(/milestoneRef|milestone_ref/i),
    });
  });

  it('AC-S2-05: contractId not found raises ("Contract not found")', async () => {
    const observedAt = new Date().toISOString();
    await expect(
      callFnAsWithTenant(PLATFORM_ADMIN.id, ADNOC_TENANT_ID, 'fn_internal_signal_ingest', [{
        signalType: 'milestone_slippage',
        contractId: 99999999, // non-existent
        milestoneRef: `M-FAKE-${RUN_ID}`,
        observedAt,
      }]),
    ).rejects.toMatchObject({
      message: expect.stringMatching(/Contract not found/i),
    });
  });
});

// ============================================================================
// AC-S5-01 / AC-S5-03 / AC-S5-04 / AC-S5-05 / AC-S5-06 — fn_internal_signal_resolve
// ============================================================================

describe('CR-A2 — fn_internal_signal_resolve (post-113 patch)', () => {
  let EPC_CONTRACT_ID: number;

  beforeAll(async () => {
    const rows = await adminQuery<{ id: string }>(
      `SELECT id::text AS id FROM contract WHERE contract_number = 'CRA2-EPC-2026-001'`,
    );
    EPC_CONTRACT_ID = Number(rows[0]!.id);
  });

  it('AC-S5-01: happy path — resolves and writes metadata fields; idempotent=false on first call', async () => {
    // Create a brand-new sla_breach signal to resolve (avoids polluting seed rows).
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 9).toISOString();
    const ingest: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_ingest',
      [{
        signalType: 'sla_breach',
        contractId: EPC_CONTRACT_ID,
        observedAt,
        severityCalcInput: { hoursOverSla: 12 },
      }],
    );
    const sigId = ingest.signalId;
    trackedSignalIds.push(sigId);

    // Q-DA3 mapping: sla_breach is allowed for Super Admin / platform_admin.
    // PLATFORM_ADMIN role 'platform_admin' is in the allowlist.
    const r: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_resolve',
      [PLATFORM_ADMIN.id, sigId, 'cleared', 'CR-A2 test resolution'],
    );
    expect(r.signalId).toBe(sigId);
    expect(r.idempotent).toBe(false);
    expect(typeof r.resolvedAt).toBe('string');
    expect(r.resolvedBy).toBe(PLATFORM_ADMIN.id);
    expect(r.resolutionKind).toBe('cleared');

    // Confirm the row's metadata carries all 4 keys.
    const rows = await adminQuery<{ metadata: any }>(
      `SELECT metadata FROM osint_signal WHERE id = $1`,
      [sigId],
    );
    const m = rows[0]!.metadata as Record<string, unknown>;
    expect(m.resolvedAt).toBeDefined();
    expect(m.resolvedBy).toBe(PLATFORM_ADMIN.id);
    expect(m.resolutionKind).toBe('cleared');
    expect(m.resolutionNote).toBe('CR-A2 test resolution');
  });

  it('AC-S5-03: re-resolving an already-resolved signal returns idempotent=true with same resolvedAt', async () => {
    // Use a fresh signal so the first call is a true first-resolve.
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 13).toISOString();
    const ingest: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_ingest',
      [{
        signalType: 'sla_breach',
        contractId: EPC_CONTRACT_ID,
        observedAt,
      }],
    );
    const sigId = ingest.signalId;
    trackedSignalIds.push(sigId);

    const r1: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_resolve',
      [PLATFORM_ADMIN.id, sigId, 'cleared', 'first call'],
    );
    expect(r1.idempotent).toBe(false);
    const firstResolvedAt = r1.resolvedAt;

    const r2: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_resolve',
      [PLATFORM_ADMIN.id, sigId, 'cleared', 'second call'],
    );
    expect(r2.idempotent).toBe(true);
    expect(r2.resolvedAt).toBe(firstResolvedAt);
    expect(r2.resolutionKind).toBe('cleared'); // ORIGINAL value, NOT the second call's input
  });

  it('AC-S5-06: signal id not found raises P0002 "Signal not found"', async () => {
    await expect(
      callFnAsWithTenant(PLATFORM_ADMIN.id, ADNOC_TENANT_ID, 'fn_internal_signal_resolve', [
        PLATFORM_ADMIN.id, 99999999, 'cleared', null,
      ]),
    ).rejects.toMatchObject({
      message: expect.stringMatching(/Signal not found/i),
    });
  });

  it('Q-DA3 permission gate: drafter (lacks internal_signal.resolve) raises 42501', async () => {
    // Pick any open signal — use a fresh one so this test is independent.
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 17).toISOString();
    const ingest: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_ingest',
      [{
        signalType: 'sla_breach',
        contractId: EPC_CONTRACT_ID,
        observedAt,
      }],
    );
    trackedSignalIds.push(ingest.signalId);

    await expect(
      callFnAsWithTenant(DRAFTER.id, ADNOC_TENANT_ID, 'fn_internal_signal_resolve', [
        DRAFTER.id, ingest.signalId, 'cleared', null,
      ]),
    ).rejects.toMatchObject({ code: '42501' });
  });
});

// ============================================================================
// AC-S4-01 / AC-S4-02 / AC-S4-03 / AC-S4-04 — fn_internal_signal_list
// ============================================================================

describe('CR-A2 — fn_internal_signal_list', () => {
  it('AC-S4-01: returns paginated envelope { data, pagination }', async () => {
    const r: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_list',
      [PLATFORM_ADMIN.id, {}, 1, 100],
    );
    expect(Array.isArray(r.data)).toBe(true);
    expect(r.pagination).toBeDefined();
    expect(typeof r.pagination.total).toBe('number');
    expect(typeof r.pagination.page).toBe('number');
    expect(typeof r.pagination.limit).toBe('number');
    expect(typeof r.pagination.totalPages).toBe('number');

    // Every row must have kind='internal' (per fn body).
    for (const row of r.data) {
      expect(row.kind).toBe('internal');
    }
  });

  it('AC-S4-02 (signalType filter): signalType=milestone_slippage returns the 4 EPC seed rows (within 180d)', async () => {
    const sinceIso = new Date(Date.now() - 1000 * 60 * 60 * 24 * 180).toISOString();
    const r: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id,
      ADNOC_TENANT_ID,
      'fn_internal_signal_list',
      [PLATFORM_ADMIN.id, { signalType: 'milestone_slippage', since: sinceIso }, 1, 100],
    );
    // Seed pack inserts 4 milestone_slippage rows on EPC contract within
    // the last 180 days (170/120/60/30 days back). The CR-A2 test suite
    // also injects a couple via the ingest tests above, but those use
    // unique milestoneRefs so dedup_hash is distinct from seed. Floor: 4.
    const milestoneRows = r.data.filter((d: any) => d.signalType === 'milestone_slippage');
    expect(milestoneRows.length).toBeGreaterThanOrEqual(4);
  });

  it('AC-S4-02 (status filter): status=open|resolved partition the result set', async () => {
    const allR: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id, ADNOC_TENANT_ID, 'fn_internal_signal_list',
      [PLATFORM_ADMIN.id, {}, 1, 100],
    );
    const openR: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id, ADNOC_TENANT_ID, 'fn_internal_signal_list',
      [PLATFORM_ADMIN.id, { status: 'open' }, 1, 100],
    );
    const resolvedR: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id, ADNOC_TENANT_ID, 'fn_internal_signal_list',
      [PLATFORM_ADMIN.id, { status: 'resolved' }, 1, 100],
    );

    // Every open row must have resolvedAt=null in the projection.
    for (const row of openR.data) {
      expect(row.resolvedAt).toBeNull();
    }
    // Every resolved row must have a non-null resolvedAt.
    for (const row of resolvedR.data) {
      expect(row.resolvedAt).not.toBeNull();
    }
    // open + resolved totals should sum to ≤ all (some may not match either if metadata had unexpected shape).
    expect(openR.pagination.total + resolvedR.pagination.total).toBeLessThanOrEqual(
      allR.pagination.total,
    );
  });

  it('AC-S4-03: drafter (no internal_signal.read) raises 42501', async () => {
    await expect(
      callFnAsWithTenant(DRAFTER.id, ADNOC_TENANT_ID, 'fn_internal_signal_list', [
        DRAFTER.id, {}, 1, 10,
      ]),
    ).rejects.toMatchObject({ code: '42501' });
  });

  it('AC-S8-02 / AC-S4-04: cross-tenant request returns empty data array (RLS narrowing)', async () => {
    // Set the GUC to a tenant that has no internal_signal_kind / osint_signal rows.
    // RLS predicates on internal_signal_kind + osint_signal narrow to current_tenant_id;
    // an unknown tenant UUID yields zero matches.
    const r: any = await callFnAsWithTenant(
      PLATFORM_ADMIN.id, OTHER_TENANT_ID, 'fn_internal_signal_list',
      [PLATFORM_ADMIN.id, {}, 1, 100],
    );
    expect(r.data).toEqual([]);
    expect(r.pagination.total).toBe(0);
  });
});

// ============================================================================
// AC-S3-01 hero invariant — count_in_180_days for EPC milestone_slippage
// ============================================================================

describe('CR-A2 — AC-S3-01 hero seed invariant', () => {
  it('AC-S3-01: at least 4 milestone_slippage rows on the EPC contract within 180 days', async () => {
    // SELECT count(*) FROM osint_signal WHERE contract_id = <epc> AND
    //   signal_kind_subtype='milestone_slippage' AND fetched_at > now() - 180d.
    // contract_id lives inside raw_payload.contractId, not as a top-level column
    // (db-design.md §1 — osint_signal does NOT carry contract_id directly).
    const rows = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count
         FROM osint_signal
        WHERE tenant_id = $1
          AND signal_kind_subtype = 'milestone_slippage'
          AND fetched_at > now() - interval '180 days'
          AND (raw_payload->>'contractId')::BIGINT = (
            SELECT id FROM contract WHERE contract_number = 'CRA2-EPC-2026-001'
          )`,
      [ADNOC_TENANT_ID],
    );
    expect(Number(rows[0]!.count)).toBeGreaterThanOrEqual(4);
  });
});

// ============================================================================
// S2-21 PUBLIC EXECUTE baseline — none of M8 fn_'s expose PUBLIC EXECUTE
// ============================================================================

describe('CR-A2 — S2-21 PUBLIC EXECUTE baseline', () => {
  it('M8 fn_ functions have NO PUBLIC EXECUTE grants', async () => {
    const rows = await adminQuery<{ proname: string }>(
      `SELECT DISTINCT p.proname
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         JOIN aclexplode(p.proacl) acl ON TRUE
        WHERE n.nspname = 'public'
          AND acl.privilege_type = 'EXECUTE'
          AND acl.grantee = 0
          AND p.proname IN (
            'fn_internal_signal_ingest',
            'fn_internal_signal_resolve',
            'fn_internal_signal_kind_list',
            'fn_internal_signal_list'
          )`,
    );
    expect(rows.map((r) => r.proname)).toEqual([]);
  });
});
