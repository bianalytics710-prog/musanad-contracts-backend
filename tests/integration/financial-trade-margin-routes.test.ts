/**
 * CR-O — Integration tests: Oil-Trade Margin HTTP routes.
 *
 * Routes under /api/v1/financial/trade-margin + /api/v1/financial/price-benchmarks:
 *   GET  /api/v1/financial/trade-margin               (positions list)
 *   GET  /api/v1/financial/trade-margin/aggregate     (CFO rollup)
 *   GET  /api/v1/financial/trade-margin/:positionId   (position detail)
 *   GET  /api/v1/financial/trade-margin/:positionId/history  (snapshot history)
 *   GET  /api/v1/financial/price-benchmarks           (benchmark list)
 *   POST /api/v1/financial/price-benchmarks           (record benchmark)
 *   POST /api/v1/financial/price-benchmarks/recompute (OSP-drop demo trigger)
 *
 * NF-1 verification:
 *   After POST /price-benchmarks/recompute with a new OSP, the executive
 *   dashboard (GET /api/v1/dashboards/executive) must return a tradeMarginSummary
 *   .recentMarginChange.deltaAed that matches the recompute response deltaAed —
 *   NOT a frozen literal.
 *
 * Envelope convention (bare fn_ JSONB — no {success, data} wrapper):
 *   Controllers return res.json(result) directly.
 *   Tests assert on res.body.data for paginated lists, or res.body for single.
 *
 * ACs covered:
 *   AC#1  Positions list 200 + data array non-empty; drafter 403
 *   AC#2  Aggregate 200 + breakdown[]; drafter 403
 *   AC#3  Position detail 200; unknown id 404
 *   AC#4  Snapshot history 200
 *   AC#5  Benchmark list 200
 *   AC#6  POST recompute 200 + deltaAed non-zero; drafter 403
 *   NF-1  Executive dashboard recentMarginChange.deltaAed matches recompute output
 *
 * testLevels: ["unit", "integration"] — no e2e (--no-walk CR)
 * Runs against TEST_DATABASE_URL (migrations 310..321 applied).
 * ADNOC tenant id = '00000000-0000-0000-0000-000000000001'.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  loginAdmin,
  adminQuery,
  closeAdminPool,
  adminPool,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  seedFixtureUsers,
  signFixtureToken,
} from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;

let financeTreasuryToken: string;
let drafterToken: string;
let platformAdminToken: string;
let executiveToken: string;
let superAdminToken: string;

// Position ID resolved from DB (TP-MURBAN-KR-JUN26)
let junPositionId: number;

// ─────────────────────────────────────────────────────────────────────────────
// Role-user seed helper
// ─────────────────────────────────────────────────────────────────────────────
async function seedRoleUserDirect(roleName: string, email: string): Promise<number> {
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
         VALUES ($1, '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS', 'CROInt', $2, $3, TRUE, 1, 1)
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
// Setup / teardown
// ─────────────────────────────────────────────────────────────────────────────

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;

  admin = await loginAdmin(app);

  await seedFixtureUsers();

  const financeTreasuryId = await seedRoleUserDirect('finance_treasury', 'cro-int-ft1@test.cro');
  const executiveId       = await seedRoleUserDirect('executive',        'cro-int-exec1@test.cro');

  const { signAccessToken } = await import('../../src/utils/jwt.util');
  financeTreasuryToken = signAccessToken({ userId: financeTreasuryId, role: 'finance_treasury' });
  executiveToken       = signAccessToken({ userId: executiveId,        role: 'executive' });
  drafterToken         = signFixtureToken('drafter1');
  platformAdminToken   = signFixtureToken('platform_admin1');
  // admin token from loginAdmin (Super Admin — finance.trade.manage)
  superAdminToken      = admin.accessToken;

  // Resolve position id
  const posRows = await adminQuery<{ id: number }>(
    `SELECT id FROM trade_position WHERE tenant_id = $1 AND position_ref = 'TP-MURBAN-KR-JUN26' AND is_active = TRUE LIMIT 1`,
    [ADNOC_TENANT_ID],
  );
  if (posRows.length > 0) {
    junPositionId = Number(posRows[0]!.id);
  }
}, 90_000);

afterAll(async () => {
  await closeAdminPool();
  if (server) server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 30_000);

// ─────────────────────────────────────────────────────────────────────────────
// AC#1 — GET /api/v1/financial/trade-margin  (positions list)
// ─────────────────────────────────────────────────────────────────────────────
describe('GET /api/v1/financial/trade-margin (positions list)', () => {
  const ROUTE = '/api/v1/financial/trade-margin';

  it('AC#1-int-01: finance_treasury → 200 + data array non-empty', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(200);
    // Guard: no extra {success, data} envelope
    expect((res.body as Record<string, unknown>).success).toBeUndefined();
    const body = res.body as { data: unknown[]; pagination: unknown };
    expect(Array.isArray(body.data)).toBe(true);
    expect(body.data.length).toBeGreaterThanOrEqual(4);
    expect(body).toHaveProperty('pagination');
  });

  it('AC#1-int-02: side=sell filter returns only sell positions', async () => {
    const res = await request(app)
      .get(`${ROUTE}?side=sell`)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(200);
    const data = (res.body as { data: Array<{ side: string }> }).data;
    for (const pos of data) {
      expect(pos.side).toBe('sell');
    }
  });

  it('AC#1-int-03: drafter → 403', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#2 — GET /api/v1/financial/trade-margin/aggregate
// ─────────────────────────────────────────────────────────────────────────────
describe('GET /api/v1/financial/trade-margin/aggregate', () => {
  const ROUTE = '/api/v1/financial/trade-margin/aggregate';

  it('AC#2-int-01: finance_treasury → 200 + breakdown array', async () => {
    const res = await request(app)
      .get(`${ROUTE}?groupBy=side`)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(200);
    const body = res.body as {
      totalMarginAed: string;
      totalMarginUsd: string;
      positionCount: number;
      breakdown: unknown[];
    };
    expect(body).toHaveProperty('totalMarginAed');
    expect(body).toHaveProperty('totalMarginUsd');
    expect(body).toHaveProperty('positionCount');
    expect(Array.isArray(body.breakdown)).toBe(true);
    expect(body.breakdown.length).toBeGreaterThanOrEqual(1);
  });

  it('AC#2-int-02: drafter → 403', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#3 — GET /api/v1/financial/trade-margin/:positionId
// ─────────────────────────────────────────────────────────────────────────────
describe('GET /api/v1/financial/trade-margin/:positionId', () => {
  it('AC#3-int-01: valid positionId → 200 + detail', async () => {
    if (!junPositionId) {
      console.warn('junPositionId not resolved — skipping');
      return;
    }
    const res = await request(app)
      .get(`/api/v1/financial/trade-margin/${junPositionId}`)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(200);
    const body = res.body as Record<string, unknown>;
    expect(body).toHaveProperty('positionRef', 'TP-MURBAN-KR-JUN26');
    expect(body).toHaveProperty('costComponents');
    expect(body).toHaveProperty('latestMargin');
  });

  it('AC#3-int-02: unknown positionId → 404', async () => {
    const res = await request(app)
      .get('/api/v1/financial/trade-margin/999999999')
      .set('Authorization', `Bearer ${financeTreasuryToken}`);
    expect(res.status).toBe(404);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#4 — GET /api/v1/financial/trade-margin/:positionId/history
// ─────────────────────────────────────────────────────────────────────────────
describe('GET /api/v1/financial/trade-margin/:positionId/history', () => {
  it('AC#4-int-01: valid positionId → 200 + snapshots array', async () => {
    if (!junPositionId) {
      console.warn('junPositionId not resolved — skipping');
      return;
    }
    const res = await request(app)
      .get(`/api/v1/financial/trade-margin/${junPositionId}/history`)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(200);
    const body = res.body as { tradePositionId: number; count: number; snapshots: unknown[] };
    expect(body).toHaveProperty('tradePositionId');
    expect(body).toHaveProperty('count');
    expect(Array.isArray(body.snapshots)).toBe(true);
    expect(body.count).toBeGreaterThanOrEqual(1);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#5 — GET /api/v1/financial/price-benchmarks
// ─────────────────────────────────────────────────────────────────────────────
describe('GET /api/v1/financial/price-benchmarks', () => {
  const ROUTE = '/api/v1/financial/price-benchmarks';

  it('AC#5-int-01: finance_treasury → 200 + murban_osp series', async () => {
    const res = await request(app)
      .get(`${ROUTE}?benchmarkCode=murban_osp`)
      .set('Authorization', `Bearer ${financeTreasuryToken}`);

    expect(res.status).toBe(200);
    const body = res.body as { data: Array<{ benchmarkCode: string }>; pagination: unknown };
    expect(Array.isArray(body.data)).toBe(true);
    expect(body.data.length).toBeGreaterThanOrEqual(1);
    for (const row of body.data) {
      expect(row.benchmarkCode).toBe('murban_osp');
    }
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC#6 — POST /api/v1/financial/price-benchmarks/recompute
// ─────────────────────────────────────────────────────────────────────────────
describe('POST /api/v1/financial/price-benchmarks/recompute', () => {
  const ROUTE = '/api/v1/financial/price-benchmarks/recompute';

  it('AC#6-int-01: Super Admin (finance.trade.manage) → 200 + deltaAed', async () => {
    // First set price to known baseline
    await request(app)
      .post(ROUTE)
      .set('Authorization', `Bearer ${superAdminToken}`)
      .send({ benchmarkCode: 'murban_osp', newPrice: 110.75 });

    // Now trigger the OSP-drop
    const res = await request(app)
      .post(ROUTE)
      .set('Authorization', `Bearer ${superAdminToken}`)
      .send({ benchmarkCode: 'murban_osp', newPrice: 104.44 });

    expect(res.status).toBe(200);
    const body = res.body as {
      benchmarkCode: string;
      deltaAed: string;
      deltaUsd: string;
      positionsRecomputed: number;
    };
    expect(body).toHaveProperty('benchmarkCode', 'murban_osp');
    expect(body).toHaveProperty('deltaAed');
    expect(body).toHaveProperty('deltaUsd');
    // Price dropped → negative delta
    expect(parseFloat(body.deltaAed)).toBeLessThan(0);
    // Restore
    await request(app)
      .post(ROUTE)
      .set('Authorization', `Bearer ${superAdminToken}`)
      .send({ benchmarkCode: 'murban_osp', newPrice: 110.75 });
  });

  it('AC#6-int-02: drafter → 403', async () => {
    const res = await request(app)
      .post(ROUTE)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ benchmarkCode: 'murban_osp', newPrice: 100.00 });
    expect(res.status).toBe(403);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// NF-1 — Executive dashboard recentMarginChange reflects computed recompute delta
// ─────────────────────────────────────────────────────────────────────────────
describe('NF-1 — fn_dashboard_executive recentMarginChange matches recompute output', () => {
  it('NF-1-int-01: after OSP recompute, dashboard deltaAed = recompute.deltaAed (not literal)', async () => {
    const RECOMPUTE = '/api/v1/financial/price-benchmarks/recompute';
    const DASHBOARD = '/api/v1/dashboards/executive';

    // Establish baseline at 110.75
    await request(app)
      .post(RECOMPUTE)
      .set('Authorization', `Bearer ${superAdminToken}`)
      .send({ benchmarkCode: 'murban_osp', newPrice: 110.75 });

    // OSP-drop to 104.44 (Story 2a demo trigger)
    const recomputeRes = await request(app)
      .post(RECOMPUTE)
      .set('Authorization', `Bearer ${superAdminToken}`)
      .send({ benchmarkCode: 'murban_osp', newPrice: 104.44 });

    expect(recomputeRes.status).toBe(200);
    const recomputeDeltaAed = parseFloat(
      (recomputeRes.body as { deltaAed: string }).deltaAed,
    );
    expect(recomputeDeltaAed).toBeLessThan(0);

    // Executive dashboard should reflect this computed delta
    const dashRes = await request(app)
      .get(DASHBOARD)
      .set('Authorization', `Bearer ${executiveToken}`);

    expect(dashRes.status).toBe(200);
    const dashBody = dashRes.body as Record<string, unknown>;
    const tms = dashBody.tradeMarginSummary as Record<string, unknown>;
    expect(tms).toBeDefined();
    const rmc = tms.recentMarginChange as Record<string, string> | null;
    expect(rmc).not.toBeNull();
    expect(rmc).toHaveProperty('deltaAed');
    expect(rmc).toHaveProperty('deltaUsd');
    expect(rmc).toHaveProperty('benchmarkCode', 'murban_osp');

    const dashDeltaAed = parseFloat(rmc!.deltaAed);

    // Dashboard delta must match recompute output within $1 (NUMERIC rounding)
    expect(Math.abs(dashDeltaAed - recomputeDeltaAed)).toBeLessThan(1);
    // Must be negative — confirming derived from real data, not a positive literal
    expect(dashDeltaAed).toBeLessThan(0);

    // Restore
    await request(app)
      .post(RECOMPUTE)
      .set('Authorization', `Bearer ${superAdminToken}`)
      .send({ benchmarkCode: 'murban_osp', newPrice: 110.75 });
  });
});
