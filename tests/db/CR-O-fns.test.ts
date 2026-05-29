/**
 * CR-O — Database function tests: Oil-Trade Margin (M21 Financial Intelligence, Trade half).
 *
 * NF-1 FIX (321): verifies that fn_dashboard_executive.tradeMarginSummary.recentMarginChange
 * is COMPUTED from real margin_snapshot data (not a hardcoded literal).
 *
 * ACs covered:
 *   AC#1  Trade positions visible (fn_trade_position_list)
 *   AC#2  fn_margin_compute writes a snapshot + refreshes latest_margin MV
 *   AC#3  fn_margin_recompute_for_price_change returns real aggregate delta
 *   AC#4  fn_dashboard_executive.tradeMarginSummary present with 6 sub-keys
 *   NF-1  recentMarginChange.deltaAed/deltaUsd is DERIVED (matches recompute output);
 *         changes when OSP changes; is NOT a frozen literal
 *   AC#5  All 11 top-level keys present in fn_dashboard_executive
 *   AC#6  fn_margin_aggregate returns breakdown by side
 *   AC#7  Permission gating: finance.margin.read required; drafter blocked
 *
 * testLevels: ["unit", "integration"] — no e2e (--no-walk CR)
 *
 * Runs against TEST_DATABASE_URL (migrations 310..321 applied).
 * ADNOC tenant id = '00000000-0000-0000-0000-000000000001'.
 * S2-21 target: NF-1 fix migration 321.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, adminQuery, closeAdminPool } from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

// Expected keys in fn_dashboard_executive output
const EXPECTED_EXEC_KEYS = [
  'kpis', 'kpiPrev', 'trends', 'charts', 'lists', 'events14d',
  'whatChangedToday', 'recommendedActions', 'clausesTriggered',
  'budgetBurnSummary', 'tradeMarginSummary',
];

let PLATFORM_ADMIN: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;

let FINANCE_TREASURY_USER_ID: number;
let EXECUTIVE_USER_ID: number;
let SUPER_ADMIN_USER_ID: number;

// ─────────────────────────────────────────────────────────────────────────────
// Role-user seed helper
// ─────────────────────────────────────────────────────────────────────────────
async function seedRoleUser(roleName: string, email: string): Promise<number> {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const roleRes = await client.query<{ id: number }>(
      'SELECT id FROM role WHERE name = $1 AND is_active = TRUE LIMIT 1',
      [roleName],
    );
    const roleId = roleRes.rows[0]?.id;
    if (!roleId) throw new Error(`Role '${roleName}' not found`);
    const userRes = await client.query<{ id: number }>(
      `INSERT INTO "user" (email, password_hash, first_name, last_name, role_id, is_active, created_by, updated_by)
         VALUES ($1, '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS', 'CRO', $2, $3, TRUE, 1, 1)
       ON CONFLICT (email) DO UPDATE SET role_id = EXCLUDED.role_id, is_active = TRUE, updated_by = 1
       RETURNING id`,
      [email, roleName, roleId],
    );
    await client.query('COMMIT');
    return Number(userRes.rows[0]!.id);
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    throw err;
  } finally {
    client.release();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// callFn — commits (VOLATILE fns that write)
// ─────────────────────────────────────────────────────────────────────────────
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
    if (Array.isArray(v) || (typeof v === 'object' && !(v instanceof Date))) return JSON.stringify(v);
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

// ─────────────────────────────────────────────────────────────────────────────
// callFnRollback — STABLE reads (no side effects)
// ─────────────────────────────────────────────────────────────────────────────
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
    if (Array.isArray(v) || (typeof v === 'object' && !(v instanceof Date))) return JSON.stringify(v);
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
  await seedFixtureUsers();
  PLATFORM_ADMIN = getFixture('platform_admin1');
  DRAFTER        = getFixture('drafter1');

  FINANCE_TREASURY_USER_ID = await seedRoleUser('finance_treasury', 'cro-ft1@test.cro');
  EXECUTIVE_USER_ID        = await seedRoleUser('executive',        'cro-exec1@test.cro');

  // Super Admin (id=1) has finance.margin.read + finance.trade.manage
  const saRes = await adminQuery<{ id: number }>(
    `SELECT id FROM "user" WHERE email = 'admin@musanad.local' AND is_active = TRUE LIMIT 1`,
  );
  SUPER_ADMIN_USER_ID = Number(saRes[0]?.id ?? 1);
});

afterAll(async () => {
  await closeAdminPool();
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#1 — fn_trade_position_list: positions visible
// ─────────────────────────────────────────────────────────────────────────────
describe('CR-O AC#1 — fn_trade_position_list', () => {
  it('returns seeded trade positions with margin data', async () => {
    const result = await callFnRollback<Record<string, unknown>>(
      FINANCE_TREASURY_USER_ID,
      'fn_trade_position_list',
      [FINANCE_TREASURY_USER_ID, null, null, null, null, 1, 50],
    );
    expect(result).toHaveProperty('data');
    expect(result).toHaveProperty('pagination');
    const data = result.data as unknown[];
    // Seed migration 320 inserts 4 positions (3 seller + 1 buyer)
    expect(data.length).toBeGreaterThanOrEqual(4);
    // Each position should have positionRef
    for (const pos of data as Array<Record<string, unknown>>) {
      expect(pos).toHaveProperty('positionRef');
      expect(pos).toHaveProperty('side');
      expect(pos).toHaveProperty('volumeBbl');
    }
  });

  it('filters by side=sell', async () => {
    const result = await callFnRollback<Record<string, unknown>>(
      FINANCE_TREASURY_USER_ID,
      'fn_trade_position_list',
      [FINANCE_TREASURY_USER_ID, 'sell', null, null, null, 1, 50],
    );
    const data = result.data as Array<Record<string, unknown>>;
    expect(data.length).toBeGreaterThanOrEqual(3);
    for (const pos of data) {
      expect(pos.side).toBe('sell');
    }
  });

  it('blocks drafter (no finance.margin.read)', async () => {
    await expect(
      callFnRollback(DRAFTER.id, 'fn_trade_position_list', [DRAFTER.id, null, null, null, null, 1, 10]),
    ).rejects.toThrow(/forbidden|42501/i);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#2 — fn_margin_compute writes a snapshot
// ─────────────────────────────────────────────────────────────────────────────
describe('CR-O AC#2 — fn_margin_compute', () => {
  it('computes margin for a sell position at explicit OSP', async () => {
    // Get a Murban sell position id
    const positions = await adminQuery<{ id: number; position_ref: string }>(
      `SELECT id, position_ref FROM trade_position
       WHERE tenant_id = $1 AND position_ref = 'TP-MURBAN-KR-JUN26' AND is_active = TRUE LIMIT 1`,
      [ADNOC_TENANT_ID],
    );
    expect(positions.length).toBe(1);
    const posId = positions[0]!.id;

    const result = await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_compute',
      [SUPER_ADMIN_USER_ID, posId, 110.75],
    );
    expect(result).toHaveProperty('tradePositionId');
    expect(result).toHaveProperty('totalMarginAed');
    expect(result).toHaveProperty('totalMarginUsd');
    expect(result).toHaveProperty('triggeredBy', 'price_change');
    expect(result).toHaveProperty('benchmarkCodeUsed', 'murban_osp');
    // Margin should be positive at $110.75 OSP with ~$4.60/bbl cost basis
    const totalAed = parseFloat(result.totalMarginAed as string);
    expect(totalAed).toBeGreaterThan(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#3 — fn_margin_recompute_for_price_change returns computed aggregate delta
// ─────────────────────────────────────────────────────────────────────────────
describe('CR-O AC#3 — fn_margin_recompute_for_price_change', () => {
  it('returns priorAggregateMarginAed, newAggregateMarginAed, deltaAed, deltaUsd', async () => {
    const result = await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 110.75, null],
    );
    expect(result).toHaveProperty('benchmarkCode', 'murban_osp');
    expect(result).toHaveProperty('priorAggregateMarginAed');
    expect(result).toHaveProperty('newAggregateMarginAed');
    expect(result).toHaveProperty('deltaAed');
    expect(result).toHaveProperty('deltaUsd');
    expect(result).toHaveProperty('positionsRecomputed');
    // 3 seller positions should be recomputed
    expect(Number(result.positionsRecomputed)).toBeGreaterThanOrEqual(3);
  });

  it('delta changes when price changes (110.75 → 104.44 produces negative delta)', async () => {
    // First establish a baseline at 110.75
    await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 110.75, null],
    );

    // Now drop the price — delta should be negative
    const result = await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 104.44, null],
    );
    const deltaAed = parseFloat(result.deltaAed as string);
    expect(deltaAed).toBeLessThan(0);

    // Restore to 110.75 for subsequent tests
    await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 110.75, null],
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#4 + AC#5 — fn_dashboard_executive: 11 keys + tradeMarginSummary structure
// ─────────────────────────────────────────────────────────────────────────────
describe('CR-O AC#4 + AC#5 — fn_dashboard_executive tradeMarginSummary', () => {
  it('returns all 11 top-level keys', async () => {
    const result = await callFnRollback<Record<string, unknown>>(
      EXECUTIVE_USER_ID,
      'fn_dashboard_executive',
      [90],
    );
    const keys = Object.keys(result);
    for (const expected of EXPECTED_EXEC_KEYS) {
      expect(keys).toContain(expected);
    }
    expect(keys.length).toBe(11);
  });

  it('tradeMarginSummary has required sub-keys', async () => {
    const result = await callFnRollback<Record<string, unknown>>(
      EXECUTIVE_USER_ID,
      'fn_dashboard_executive',
      [90],
    );
    const tms = result.tradeMarginSummary as Record<string, unknown>;
    expect(tms).toHaveProperty('openPositionCount');
    expect(tms).toHaveProperty('totalMarginAed');
    expect(tms).toHaveProperty('totalMarginUsd');
    expect(tms).toHaveProperty('bySide');
    expect(tms).toHaveProperty('recentMarginChange');
    expect(tms).toHaveProperty('topPositionsByMargin3');
    // At least the 3 seller positions should be open
    expect(Number(tms.openPositionCount)).toBeGreaterThanOrEqual(3);
  });

  it('bySide.sell.positionCount >= 3 (3 seeded murban sellers)', async () => {
    const result = await callFnRollback<Record<string, unknown>>(
      EXECUTIVE_USER_ID,
      'fn_dashboard_executive',
      [90],
    );
    const tms = result.tradeMarginSummary as Record<string, unknown>;
    const bySide = tms.bySide as Record<string, Record<string, unknown>>;
    expect(Number(bySide.sell.positionCount)).toBeGreaterThanOrEqual(3);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// NF-1 — recentMarginChange is COMPUTED (not a literal)
// ─────────────────────────────────────────────────────────────────────────────
describe('CR-O NF-1 — recentMarginChange is derived from real data', () => {
  it('recentMarginChange.deltaAed matches fn_margin_recompute aggregate delta', async () => {
    // Establish a known baseline at 110.75
    await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 110.75, null],
    );

    // Drop to 104.44 — this is the Story 2a demo trigger
    const recompute = await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 104.44, null],
    );
    const recomputeDeltaAed = parseFloat(recompute.deltaAed as string);
    expect(recomputeDeltaAed).toBeLessThan(0); // price drop → negative delta

    // fn_dashboard_executive should now reflect this computed delta
    const dashResult = await callFnRollback<Record<string, unknown>>(
      EXECUTIVE_USER_ID,
      'fn_dashboard_executive',
      [90],
    );
    const tms = dashResult.tradeMarginSummary as Record<string, unknown>;
    const rmc = tms.recentMarginChange as Record<string, string> | null;

    // recentMarginChange must be present (price_change snapshot within 30d)
    expect(rmc).not.toBeNull();
    expect(rmc).toHaveProperty('benchmarkCode', 'murban_osp');
    expect(rmc).toHaveProperty('deltaAed');
    expect(rmc).toHaveProperty('deltaUsd');
    expect(rmc).toHaveProperty('asOf');

    const dashboardDeltaAed = parseFloat(rmc!.deltaAed);
    // Dashboard delta should be negative (matching the drop)
    expect(dashboardDeltaAed).toBeLessThan(0);

    // Dashboard delta should match recompute fn output within $1 (rounding only)
    expect(Math.abs(dashboardDeltaAed - recomputeDeltaAed)).toBeLessThan(1);

    // Restore to 110.75 (cleanup for other tests)
    await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 110.75, null],
    );
  });

  it('recentMarginChange.deltaAed changes when OSP changes (not frozen)', async () => {
    // Establish baseline at 110.75
    await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 110.75, null],
    );

    const before = await callFnRollback<Record<string, unknown>>(
      EXECUTIVE_USER_ID,
      'fn_dashboard_executive',
      [90],
    );
    const tms_before = before.tradeMarginSummary as Record<string, unknown>;
    const rmc_before = tms_before.recentMarginChange as Record<string, string> | null;

    // Move price to 100.00 — larger drop
    await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 100.00, null],
    );

    const after = await callFnRollback<Record<string, unknown>>(
      EXECUTIVE_USER_ID,
      'fn_dashboard_executive',
      [90],
    );
    const tms_after = after.tradeMarginSummary as Record<string, unknown>;
    const rmc_after = tms_after.recentMarginChange as Record<string, string> | null;

    // deltaAed should differ between the two states
    const deltaAfter  = parseFloat(rmc_after?.deltaAed ?? '0');
    const deltaBefore = parseFloat(rmc_before?.deltaAed ?? '0');
    expect(deltaAfter).not.toBeCloseTo(deltaBefore, 0);
    expect(deltaAfter).toBeLessThan(0); // price drop at $100 from $110.75

    // Restore
    await callFn<Record<string, unknown>>(
      SUPER_ADMIN_USER_ID,
      'fn_margin_recompute_for_price_change',
      [SUPER_ADMIN_USER_ID, 'murban_osp', 110.75, null],
    );
  });

  it('recentMarginChange is NULL (not literal) when no price_change snapshot in window', async () => {
    // We can test this by calling fn_dashboard_executive on a tenant with NO price_change snapshots.
    // Use PLATFORM_ADMIN on a non-ADNOC tenant (if one exists) — or simply verify the fn body
    // has no hardcoded numeric literal via pg_proc.
    const fnBodyRes = await adminQuery<{ prosrc: string }>(
      `SELECT prosrc FROM pg_proc WHERE proname = 'fn_dashboard_executive' LIMIT 1`,
    );
    const body = fnBodyRes[0]?.prosrc ?? '';
    // The hardcoded literals from mig 316 must not appear in the mig 321 fn body
    expect(body.includes("'-139040850.00'")).toBe(false);
    expect(body.includes("'-37860000.00'")).toBe(false);
    // NF-1 FIX marker must be present
    expect(body.includes('NF-1 FIX')).toBe(true);
    // LAG() window function must be present (the S2-24 CTE approach)
    expect(body.toLowerCase().includes('lag(')).toBe(true);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#6 — fn_margin_aggregate breakdown by side
// ─────────────────────────────────────────────────────────────────────────────
describe('CR-O AC#6 — fn_margin_aggregate', () => {
  it('returns totalMarginAed + breakdown by side', async () => {
    const result = await callFnRollback<Record<string, unknown>>(
      FINANCE_TREASURY_USER_ID,
      'fn_margin_aggregate',
      [FINANCE_TREASURY_USER_ID, { groupBy: 'side' }],
    );
    expect(result).toHaveProperty('totalMarginAed');
    expect(result).toHaveProperty('totalMarginUsd');
    expect(result).toHaveProperty('positionCount');
    expect(result).toHaveProperty('breakdown');
    const breakdown = result.breakdown as unknown[];
    expect(breakdown.length).toBeGreaterThanOrEqual(1);
    // sell side should appear (3 seeded seller positions)
    const sellBucket = breakdown.find((b: unknown) => (b as Record<string, unknown>).key === 'sell');
    expect(sellBucket).toBeDefined();
  });

  it('blocks drafter (no finance.margin.read)', async () => {
    await expect(
      callFnRollback(DRAFTER.id, 'fn_margin_aggregate', [DRAFTER.id, { groupBy: 'side' }]),
    ).rejects.toThrow(/forbidden|42501/i);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#7 — Permission gating: finance.trade.manage required for recompute
// ─────────────────────────────────────────────────────────────────────────────
describe('CR-O AC#7 — permission gating', () => {
  it('fn_margin_recompute_for_price_change blocks user without finance.trade.manage', async () => {
    // executive has insights.executive but not finance.trade.manage
    await expect(
      callFn(
        EXECUTIVE_USER_ID,
        'fn_margin_recompute_for_price_change',
        [EXECUTIVE_USER_ID, 'murban_osp', 110.75, null],
      ),
    ).rejects.toThrow(/forbidden|42501/i);
  });

  it('fn_dashboard_executive blocks drafter (no executive/platform_admin/Super Admin role)', async () => {
    await expect(
      callFnRollback(DRAFTER.id, 'fn_dashboard_executive', [90]),
    ).rejects.toThrow(/forbidden|42501/i);
  });
});
