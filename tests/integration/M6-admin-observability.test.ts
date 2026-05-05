/**
 * M6 — Admin Observability (S11–S13) integration + DB function tests.
 *
 * Surfaces:
 *   - GET /api/v1/dashboards/ai-cost-summary  (S11, fn_dashboard_ai_cost_summary)
 *   - GET /api/v1/admin/health                (S12, fn_health_check)
 *   - S13 reuses S1's GET /api/v1/dashboards/admin (verified in operational suite)
 *
 * Focus per Orchestrator brief:
 *   - S11: standalone (DASH-OI-G); wraps M4 fn_ai_request_log_cost_report
 *   - S12: returns latestMigration: 57 for admin (proves ARCH-NEW-3 option c);
 *          audit block dropped (Patch WARN-2-FIX) — health output has no
 *          errorCountLastHour field
 *
 * Invariants verified at suite scope:
 *   - S2-21: PUBLIC EXECUTE grant count is exactly 5 in the test branch
 *   - ARCH-NEW-3 option (c): schema_migrations_select_admin RLS policy exists
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  closeAdminPool,
  loginAdmin,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  seedFixtureUsers,
  signFixtureToken,
} from '../helpers/m1c-helpers';
import {
  countPublicExecuteGrantsOnFnFunctions,
  getRoleIdByName,
  grantPermissionToRole,
  hasSchemaMigrationsAdminPolicy,
  listPublicExecuteFnFunctions,
  revokePermissionFromRole,
  roleHasPermission,
  tagFor,
} from '../helpers/m6-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let executiveToken: string;
let drafterToken: string;
let recipientToken: string;

// platform_admin role id (used to flip ai.observability.read for negative test)
let platformAdminRoleId = -1;
let platformAdminHadAiObsReadAtStart = false;

const SUITE_TAG = tagFor('admin-obs');
void SUITE_TAG; // marker only; this suite seeds nothing.

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;
  await seedFixtureUsers();
  executiveToken = signFixtureToken('executive1');
  drafterToken = signFixtureToken('drafter1');
  recipientToken = signFixtureToken('recipient1');

  platformAdminRoleId = await getRoleIdByName('platform_admin');
  platformAdminHadAiObsReadAtStart = await roleHasPermission(
    platformAdminRoleId,
    'ai.observability.read',
  );
}, 60_000);

afterAll(async () => {
  // Restore platform_admin ai.observability.read to its pre-suite state.
  try {
    if (platformAdminRoleId > 0) {
      if (platformAdminHadAiObsReadAtStart) {
        await grantPermissionToRole(
          platformAdminRoleId,
          'ai.observability.read',
        );
      } else {
        await revokePermissionFromRole(
          platformAdminRoleId,
          'ai.observability.read',
        );
      }
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M6-admin-obs perm restore]', err);
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 60_000);

// ============================================================================
// S2-21 — PUBLIC EXECUTE grant count (mandatory cumulative invariant)
// ============================================================================
describe('S2-21 — PUBLIC EXECUTE grant count (M3 token-bearer allowlist preserved)', () => {
  it('S2-21: PUBLIC EXECUTE count on fn_-prefixed functions is exactly 5', async () => {
    const count = await countPublicExecuteGrantsOnFnFunctions();
    if (count !== 5) {
      // eslint-disable-next-line no-console
      console.error(
        '[S2-21 escape] PUBLIC EXECUTE fn_ list:',
        await listPublicExecuteFnFunctions(),
      );
    }
    expect(count).toBe(5);
  });

  it('S2-21: PUBLIC EXECUTE allowlist is the M3 token-bearer family', async () => {
    const names = await listPublicExecuteFnFunctions();
    expect(names.sort()).toEqual(
      [
        'fn_signature_decline',
        'fn_signature_get_by_invitation_token',
        'fn_signature_sign',
        'fn_signer_qa_session_record_message',
        'fn_signer_qa_session_start',
      ].sort(),
    );
  });
});

// ============================================================================
// ARCH-NEW-3 option (c) — schema_migrations admin SELECT policy
// ============================================================================
describe('ARCH-NEW-3 (c) — schema_migrations_select_admin RLS policy', () => {
  it('schema_migrations_select_admin policy exists', async () => {
    const exists = await hasSchemaMigrationsAdminPolicy();
    expect(exists).toBe(true);
  });
});

// ============================================================================
// S11 — fn_dashboard_ai_cost_summary
// ============================================================================
describe('S11 — fn_dashboard_ai_cost_summary / GET /api/v1/dashboards/ai-cost-summary', () => {
  it('AC-S11-01: caller with ai.observability.read returns 200 with cost summary shape', async () => {
    // platform_admin (Super Admin bootstrap) holds ai.observability.read by
    // M4 044 grants — verify happy path.
    const res = await request(app)
      .get('/api/v1/dashboards/ai-cost-summary')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('totalCostUsdWindow');
    expect(res.body).toHaveProperty('totalRequestsWindow');
    expect(res.body).toHaveProperty('cacheHitRatioOverall');
    expect(res.body).toHaveProperty('topPromptsByCost5');
    expect(typeof res.body.totalCostUsdWindow).toBe('number');
    expect(typeof res.body.totalRequestsWindow).toBe('number');
    expect(Array.isArray(res.body.topPromptsByCost5)).toBe(true);
    expect(res.body.topPromptsByCost5.length).toBeLessThanOrEqual(5);
  });

  it('AC-S11-02 / S2-18: cacheHitRatioOverall is null when totalRequestsWindow=0', async () => {
    // Drive totalRequestsWindow to 0 by querying a 1-day window in the absence
    // of fresh ai_request_log rows. We accept either of:
    //   - totalRequestsWindow > 0 → cacheHitRatioOverall is a number
    //   - totalRequestsWindow == 0 → cacheHitRatioOverall is null
    // The S2-18 NULL semantic is asserted via the conditional (null iff zero).
    const res = await request(app)
      .get('/api/v1/dashboards/ai-cost-summary')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ windowDays: 1 });
    expect(res.status).toBe(200);
    if (res.body.totalRequestsWindow === 0) {
      expect(res.body.cacheHitRatioOverall).toBeNull();
    } else {
      expect(typeof res.body.cacheHitRatioOverall).toBe('number');
    }
  });

  it('AC-S11-03: topPromptsByCost5 rows have promptId/requestCount/totalCostUsd/cacheHitRatio', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/ai-cost-summary')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    for (const row of res.body.topPromptsByCost5) {
      expect(row).toHaveProperty('promptId');
      expect(row).toHaveProperty('requestCount');
      expect(row).toHaveProperty('totalCostUsd');
      expect(row).toHaveProperty('cacheHitRatio');
    }
  });

  it('AC-S11-04: caller without ai.observability.read receives 403 (route pre-gate)', async () => {
    // contract_drafter does not hold ai.observability.read.
    const res = await request(app)
      .get('/api/v1/dashboards/ai-cost-summary')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S11-04b: contract_recipient receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/ai-cost-summary')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S11-04c: executive (without permission) receives 403', async () => {
    // executive role does NOT hold ai.observability.read by default in the
    // M4-seeded grants. If our previous suite left it granted, revoke it
    // here for the duration of this case.
    const execRoleId = await getRoleIdByName('executive');
    const had = await roleHasPermission(execRoleId, 'ai.observability.read');
    if (had) {
      await revokePermissionFromRole(execRoleId, 'ai.observability.read');
    }
    try {
      const res = await request(app)
        .get('/api/v1/dashboards/ai-cost-summary')
        .set('Authorization', `Bearer ${executiveToken}`);
      expect(res.status).toBe(403);
    } finally {
      if (had) {
        await grantPermissionToRole(execRoleId, 'ai.observability.read');
      }
    }
  });

  it('AC-S11-05: windowDays=91 returns 400 (matches M4 90-day cap)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/ai-cost-summary')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ windowDays: 91 });
    expect(res.status).toBe(400);
  });

  it('AC-S11-05b: windowDays=0 returns 400', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/ai-cost-summary')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ windowDays: 0 });
    expect(res.status).toBe(400);
  });

  it('AC-S11-05c: windowDays=90 (boundary) returns 200', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/ai-cost-summary')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ windowDays: 90 });
    expect(res.status).toBe(200);
  });
});

// ============================================================================
// S12 — fn_health_check
// ============================================================================
describe('S12 — fn_health_check / GET /api/v1/admin/health', () => {
  it('AC-S12-01: admin caller returns 200 with { db, ai, overall }', async () => {
    const res = await request(app)
      .get('/api/v1/admin/health')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('db');
    expect(res.body).toHaveProperty('ai');
    expect(res.body).toHaveProperty('overall');
  });

  it('Patch WARN-2-FIX: response has NO audit/errorCountLastHour field', async () => {
    const res = await request(app)
      .get('/api/v1/admin/health')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    // The audit block was dropped in Patch Round 1 because audit_log.action
    // CHECK enum is INSERT/UPDATE/DELETE only — 'ERROR' could never match.
    expect(res.body).not.toHaveProperty('audit');
    // Defensive — even if it appeared, it should not have errorCountLastHour.
    if ('audit' in res.body) {
      expect(res.body.audit).not.toHaveProperty('errorCountLastHour');
    }
  });

  it('AC-S12-02: db.status is "ok" or "degraded"', async () => {
    const res = await request(app)
      .get('/api/v1/admin/health')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(['ok', 'degraded']).toContain(res.body.db.status);
  });

  it('AC-S12-03 / ARCH-NEW-3 (c): db.latestMigration is exactly 57 for admin', async () => {
    const res = await request(app)
      .get('/api/v1/admin/health')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    // The schema_migrations_select_admin RLS policy in 054 enables admin SELECT
    // of MAX(version). DB live is at version 57 (Orchestrator brief).
    expect(res.body.db.latestMigration).toBe(57);
  });

  it('AC-S12-05: ai.estimatedHealthy is a boolean', async () => {
    const res = await request(app)
      .get('/api/v1/admin/health')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(typeof res.body.ai.estimatedHealthy).toBe('boolean');
    // lastSuccessfulRequestAt and lastFailureAt may be null or ISO strings.
    expect(
      res.body.ai.lastSuccessfulRequestAt === null ||
        typeof res.body.ai.lastSuccessfulRequestAt === 'string',
    ).toBe(true);
    expect(
      res.body.ai.lastFailureAt === null ||
        typeof res.body.ai.lastFailureAt === 'string',
    ).toBe(true);
  });

  it('AC-S12-06: overall is one of ok|degraded|unhealthy', async () => {
    const res = await request(app)
      .get('/api/v1/admin/health')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(['ok', 'degraded', 'unhealthy']).toContain(res.body.overall);
  });

  it('AC-S12-07: contract_drafter receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/health')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S12-07b: contract_recipient receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/health')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S12-07c: executive receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/health')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(403);
  });

  it('S12: no JWT returns 401', async () => {
    const res = await request(app).get('/api/v1/admin/health');
    expect(res.status).toBe(401);
  });
});

// ============================================================================
// S13 — Reuses S1 endpoint (covered by operational suite)
// ============================================================================
describe('S13 — Admin landing tile grid (reuses S1 fn_dashboard_admin)', () => {
  it('S13: GET /api/v1/dashboards/admin same as S1 — admin reaches 200', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    // Tiles include: Total Contracts, Pending Approvals, Pending Signatures,
    // Open Regulatory Impacts, Recent Audit Events, Total Users (AC-S13-02).
    expect(res.body.kpis.totalContractsActive).toBeDefined();
    expect(res.body.kpis.pendingApprovals).toBeDefined();
    expect(res.body.kpis.pendingSignatures).toBeDefined();
    expect(res.body.kpis.openRegulatoryImpacts).toBeDefined();
    expect(res.body.kpis.recentAuditEvents).toBeDefined();
    expect(res.body.kpis.totalActiveUsers).toBeDefined();
  });
});
