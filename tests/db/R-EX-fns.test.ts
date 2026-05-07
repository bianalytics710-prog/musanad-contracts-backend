/**
 * R-EX0..R-EX3 — Database function tests for the Executive persona work.
 *
 * Covers fn_dashboard_executive across migrations 089/090/091/093:
 *   - kpis structure (5 R-EX0 KPIs + cycleTimeFunnel)
 *   - kpiPrev block presence
 *   - charts block (5 sections: spendByCategory, topSuppliers,
 *     revenueUnderContract12m, contractThroughput12m, expiryCliff)
 *   - lists block (3 sections: highRiskContracts8,
 *     mostUsedTemplates8, mostAmendedContracts5)
 *   - events14d feed
 *   - permission gate (drafter / recipient rejected with 42501)
 *   - windowDays validation (22023)
 */
import { describe, it, expect, beforeAll } from 'vitest';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';

let EXECUTIVE: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;
let RECIPIENT: SeededFixtureUser;

beforeAll(async () => {
  await seedFixtureUsers();
  EXECUTIVE = getFixture('executive1');
  DRAFTER = getFixture('drafter1');
  RECIPIENT = getFixture('recipient1');
});

describe('fn_dashboard_executive — R-EX0 KPI shape (089)', () => {
  it('returns the 5 Lovable-parity KPIs + cycleTimeFunnel', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    expect(r.kpis).toBeDefined();
    // 5 R-EX0 KPIs
    expect(typeof r.kpis.totalActiveValueAed).toBe('number');
    expect(typeof r.kpis.activeContractsCount).toBe('number');
    expect(typeof r.kpis.avgCycleTimeDays).toBe('number');
    expect(typeof r.kpis.renewalsCount90d).toBe('number');
    expect(typeof r.kpis.renewalValueAed90d).toBe('number');
    // cycleTimeFunnel object with 4 stages
    expect(r.kpis.cycleTimeFunnel).toBeDefined();
    expect(typeof r.kpis.cycleTimeFunnel.draftingDays).toBe('number');
    expect(typeof r.kpis.cycleTimeFunnel.legalReviewDays).toBe('number');
    expect(typeof r.kpis.cycleTimeFunnel.approvalChainDays).toBe('number');
    expect(typeof r.kpis.cycleTimeFunnel.counterpartySignatureDays).toBe('number');
    // Existing M6 KPIs preserved
    expect(typeof r.kpis.openRegulatoryImpactsCritical).toBe('number');
    expect(r.kpis.contractsByStatus).toBeDefined();
    expect(r.kpis.expiryCliffs).toBeDefined();
  });

  it('returns kpiPrev block for delta computation', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    expect(r.kpiPrev).toBeDefined();
    expect(typeof r.kpiPrev.totalActiveValueAed).toBe('number');
    expect(typeof r.kpiPrev.activeContractsCount).toBe('number');
    expect(typeof r.kpiPrev.renewalsCount90d).toBe('number');
    expect(typeof r.kpiPrev.renewalValueAed90d).toBe('number');
  });
});

describe('fn_dashboard_executive — R-EX1 charts (090)', () => {
  it('returns the 5 chart sections', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    expect(r.charts).toBeDefined();
    expect(Array.isArray(r.charts.spendByCategory)).toBe(true);
    expect(Array.isArray(r.charts.topSuppliers)).toBe(true);
    expect(Array.isArray(r.charts.revenueUnderContract12m)).toBe(true);
    expect(Array.isArray(r.charts.contractThroughput12m)).toBe(true);
    expect(Array.isArray(r.charts.expiryCliff)).toBe(true);
    // 12 month series have exactly 12 points
    expect(r.charts.revenueUnderContract12m.length).toBe(12);
    expect(r.charts.contractThroughput12m.length).toBe(12);
    // expiryCliff is exactly 6 horizon buckets
    expect(r.charts.expiryCliff.length).toBe(6);
    expect(r.charts.expiryCliff.map((b: any) => b.horizon)).toEqual([
      '30d', '60d', '90d', '180d', '365d', '>365d',
    ]);
  });

  it('topSuppliers rows include sparkline12m with 12 points each', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    if (r.charts.topSuppliers.length > 0) {
      for (const s of r.charts.topSuppliers) {
        expect(typeof s.counterpartyId).toBe('number');
        expect(typeof s.name).toBe('string');
        expect(typeof s.contractCount).toBe('number');
        expect(typeof s.totalValueAed).toBe('number');
        expect(Array.isArray(s.sparkline12m)).toBe(true);
        expect(s.sparkline12m.length).toBe(12);
      }
    }
  });

  it('spendByCategory percentages sum to no more than 100', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    if (r.charts.spendByCategory.length > 0) {
      const sumPct = r.charts.spendByCategory.reduce(
        (s: number, row: any) => s + Number(row.pct),
        0,
      );
      expect(sumPct).toBeLessThanOrEqual(100.01);
    }
  });
});

describe('fn_dashboard_executive — R-EX2 lists (091)', () => {
  it('returns the 3 list sections', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    expect(r.lists).toBeDefined();
    expect(Array.isArray(r.lists.highRiskContracts8)).toBe(true);
    expect(Array.isArray(r.lists.mostUsedTemplates8)).toBe(true);
    expect(Array.isArray(r.lists.mostAmendedContracts5)).toBe(true);
    expect(r.lists.highRiskContracts8.length).toBeLessThanOrEqual(8);
    expect(r.lists.mostUsedTemplates8.length).toBeLessThanOrEqual(8);
    expect(r.lists.mostAmendedContracts5.length).toBeLessThanOrEqual(5);
  });

  it('highRiskContracts8 sorted by riskScore DESC', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    const scores = r.lists.highRiskContracts8.map((row: any) => row.riskScore);
    for (let i = 1; i < scores.length; i++) {
      expect(scores[i - 1]).toBeGreaterThanOrEqual(scores[i]);
    }
  });

  it('mostAmendedContracts5 amendmentCount = currentVersion - 1 (clamped to 0)', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    for (const row of r.lists.mostAmendedContracts5) {
      const expected = Math.max((row.currentVersion ?? 0) - 1, 0);
      expect(row.amendmentCount).toBe(expected);
    }
  });
});

describe('fn_dashboard_executive — R-EX3 events14d (093)', () => {
  it('returns events14d as an array (at most 8)', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    expect(Array.isArray(r.events14d)).toBe(true);
    expect(r.events14d.length).toBeLessThanOrEqual(8);
    if (r.events14d.length > 0) {
      const ev = r.events14d[0];
      expect(typeof ev.eventType).toBe('string');
      expect(typeof ev.headline).toBe('string');
      expect(typeof ev.occurredAt).toBe('string');
      expect(['critical', 'high', 'low']).toContain(ev.severity);
    }
  });

  it('events14d sorted by occurredAt DESC', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [90]);
    if (r.events14d.length > 1) {
      for (let i = 1; i < r.events14d.length; i++) {
        const prev = new Date(r.events14d[i - 1].occurredAt).getTime();
        const curr = new Date(r.events14d[i].occurredAt).getTime();
        expect(prev).toBeGreaterThanOrEqual(curr);
      }
    }
  });
});

describe('fn_dashboard_executive — permission gate', () => {
  it('rejects contract_drafter with 42501', async () => {
    await expect(
      callFnAs(DRAFTER.id, 'fn_dashboard_executive', [90]),
    ).rejects.toThrow(/forbidden|42501/);
  });

  it('rejects contract_recipient with 42501', async () => {
    await expect(
      callFnAs(RECIPIENT.id, 'fn_dashboard_executive', [90]),
    ).rejects.toThrow(/forbidden|42501/);
  });
});

describe('fn_dashboard_executive — input validation', () => {
  it('rejects windowDays = 0 with 22023', async () => {
    await expect(
      callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [0]),
    ).rejects.toThrow(/windowDays|22023/);
  });

  it('rejects windowDays = 366 with 22023', async () => {
    await expect(
      callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [366]),
    ).rejects.toThrow(/windowDays|22023/);
  });

  it('accepts default windowDays via NULL', async () => {
    const r: any = await callFnAs(EXECUTIVE.id, 'fn_dashboard_executive', [null]);
    expect(r.kpis).toBeDefined();
  });
});
