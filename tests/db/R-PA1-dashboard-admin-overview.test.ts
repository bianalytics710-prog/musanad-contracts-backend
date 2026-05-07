/**
 * R-PA1 — fn_dashboard_admin overview shape (migration 095).
 *
 * Asserts the function returns the 7 top-level keys required by the
 * Platform Admin foundation dashboard:
 *   kpis, kpiPrev, trends, systemHealth, pendingAdminActions,
 *   topContractTypes5, systemActivity14d
 *
 * Plus light shape checks on each new section + the existing permission
 * gate (drafter rejected).
 */
import { describe, it, expect, beforeAll } from 'vitest';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';

let PLATFORM_ADMIN: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;

beforeAll(async () => {
  await seedFixtureUsers();
  PLATFORM_ADMIN = getFixture('platform_admin1');
  DRAFTER = getFixture('drafter1');
});

describe('R-PA1 — fn_dashboard_admin overview keys', () => {
  it('returns the 7 expected top-level keys', async () => {
    const r: any = await callFnAs(PLATFORM_ADMIN.id, 'fn_dashboard_admin', [30]);
    expect(r).toBeDefined();
    expect(r.kpis).toBeDefined();
    expect(r.kpiPrev).toBeDefined();
    expect(r.trends).toBeDefined();
    expect(r.systemHealth).toBeDefined();
    expect(r.pendingAdminActions).toBeDefined();
    expect(Array.isArray(r.topContractTypes5)).toBe(true);
    expect(Array.isArray(r.systemActivity14d)).toBe(true);
  });

  it('kpiPrev mirrors the kpi number keys', async () => {
    const r: any = await callFnAs(PLATFORM_ADMIN.id, 'fn_dashboard_admin', [30]);
    for (const key of [
      'totalContractsActive',
      'expiringWithin30d',
      'expiringWithin90d',
      'pendingApprovals',
      'pendingSignatures',
      'openRegulatoryImpacts',
      'recentAuditEvents',
      'totalActiveUsers',
    ]) {
      expect(typeof r.kpiPrev[key]).toBe('number');
    }
  });

  it('systemHealth has dbStatus + latestMigration + 24h counters', async () => {
    const r: any = await callFnAs(PLATFORM_ADMIN.id, 'fn_dashboard_admin', [30]);
    expect(r.systemHealth.dbStatus).toBe('ok');
    expect(typeof r.systemHealth.latestMigration).toBe('number');
    expect(r.systemHealth.latestMigration).toBeGreaterThanOrEqual(95);
    expect(typeof r.systemHealth.auditEvents24h).toBe('number');
    expect(typeof r.systemHealth.aiErrors24h).toBe('number');
  });

  it('pendingAdminActions has 4 numeric counters', async () => {
    const r: any = await callFnAs(PLATFORM_ADMIN.id, 'fn_dashboard_admin', [30]);
    expect(typeof r.pendingAdminActions.pendingApprovals).toBe('number');
    expect(typeof r.pendingAdminActions.pendingSignatures).toBe('number');
    expect(typeof r.pendingAdminActions.pendingImports).toBe('number');
    expect(typeof r.pendingAdminActions.openImpacts).toBe('number');
  });

  it('topContractTypes5 returns at most 5 rows sorted DESC by count', async () => {
    const r: any = await callFnAs(PLATFORM_ADMIN.id, 'fn_dashboard_admin', [30]);
    expect(r.topContractTypes5.length).toBeLessThanOrEqual(5);
    for (let i = 1; i < r.topContractTypes5.length; i++) {
      expect(r.topContractTypes5[i - 1].count).toBeGreaterThanOrEqual(
        r.topContractTypes5[i].count,
      );
    }
  });

  it('systemActivity14d returns at most 8 rows sorted DESC by occurredAt', async () => {
    const r: any = await callFnAs(PLATFORM_ADMIN.id, 'fn_dashboard_admin', [30]);
    expect(r.systemActivity14d.length).toBeLessThanOrEqual(8);
    if (r.systemActivity14d.length > 1) {
      for (let i = 1; i < r.systemActivity14d.length; i++) {
        const prev = new Date(r.systemActivity14d[i - 1].occurredAt).getTime();
        const curr = new Date(r.systemActivity14d[i].occurredAt).getTime();
        expect(prev).toBeGreaterThanOrEqual(curr);
      }
    }
  });
});

describe('R-PA1 — fn_dashboard_admin permission gate', () => {
  it('rejects contract_drafter with 42501', async () => {
    await expect(
      callFnAs(DRAFTER.id, 'fn_dashboard_admin', [30]),
    ).rejects.toThrow(/forbidden|42501/);
  });

  it('rejects windowDays = 0 with 22023', async () => {
    await expect(
      callFnAs(PLATFORM_ADMIN.id, 'fn_dashboard_admin', [0]),
    ).rejects.toThrow(/windowDays|22023/);
  });
});
