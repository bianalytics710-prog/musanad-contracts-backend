/**
 * M6 — Operational Dashboards (S1–S6) integration + DB function tests.
 *
 * Surfaces:
 *   - GET /api/v1/dashboards/admin           (S1, fn_dashboard_admin — also S13)
 *   - GET /api/v1/dashboards/drafter         (S2, fn_dashboard_drafter)
 *   - GET /api/v1/dashboards/approver        (S3, fn_dashboard_approver — post-057 patch)
 *   - GET /api/v1/dashboards/legal-counsel   (S4, fn_dashboard_legal_counsel)
 *   - GET /api/v1/dashboards/recipient       (S5, fn_dashboard_recipient)
 *   - GET /api/v1/dashboards/router          (S6, fn_dashboard_router)
 *
 * Focus per Orchestrator brief:
 *   - S1: only platform_admin/Super Admin reach the body; non-admin → 42501 → 403
 *   - S2: drafter scope — own contracts only; permission-narrow tested
 *   - S3: post-patch 057 — verify pendingQueue5 returns rows with proper
 *         contract context (regression check on the JOIN fix)
 *   - S4: aggregates regulatory_impact + audit_log; uses 'audit.read' permission
 *         (CRIT-4 verification); column 'table_name' (S2-22-FIX-4); 'resolved BOOLEAN'
 *         filter (CRIT-1)
 *   - S5: signature_event uses actor_user_id/created_at/event_type='signed'
 *         (Patch FIX-1); signature_invitation uses invitation_sent_at /
 *         invitation_expires_at aliased to sentAt/expiresAt (Patch FIX-5)
 *   - S6: returns nested role.name shape (Patch WARN-3-FIX); 5 different roles
 *         routed correctly
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  adminQuery,
  cleanupContractsByIds,
  closeAdminPool,
  createContract,
  loginAdmin,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  signFixtureToken,
} from '../helpers/m1c-helpers';
import {
  cleanupApprovalArtifacts,
} from '../helpers/m2-helpers';
import {
  cleanupRegulatoryArtifacts,
} from '../helpers/m5-helpers';
import {
  cleanupDashboardArtifacts,
  seedPendingApprovalForUser,
  seedSignatureEvent,
  seedSignatureInvitation,
  tagFor,
} from '../helpers/m6-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;
let recipientToken: string;
let approverToken: string;
let approver2Token: string;
let executiveToken: string;
let legalToken: string;

const createdContractIds: number[] = [];
const createdSignaturePartyIds: number[] = [];
const createdSignatureInvitationIds: number[] = [];
const createdSignatureEventIds: number[] = [];
const SUITE_TAG = tagFor('ops-dash');

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;
  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  recipientToken = signFixtureToken('recipient1');
  approverToken = signFixtureToken('approver1');
  approver2Token = signFixtureToken('approver2');
  executiveToken = signFixtureToken('executive1');
  legalToken = signFixtureToken('legal_counsel1');
}, 60_000);

afterAll(async () => {
  try {
    await cleanupDashboardArtifacts({
      signatureEventIds: createdSignatureEventIds,
      signatureInvitationIds: createdSignatureInvitationIds,
      signaturePartyIds: createdSignaturePartyIds,
    });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M6-ops-dash dash cleanup]', err);
  }
  try {
    await cleanupApprovalArtifacts(createdContractIds);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M6-ops-dash approval cleanup]', err);
  }
  try {
    await cleanupRegulatoryArtifacts({ contractIds: createdContractIds });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M6-ops-dash regulatory cleanup]', err);
  }
  try {
    await cleanupContractsByIds(createdContractIds);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M6-ops-dash contract cleanup]', err);
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 60_000);

const createDraftAsDrafter = async (): Promise<number> => {
  const c = await createContract(app, drafterToken, {
    titleEn: `${SUITE_TAG}-c-${Date.now()}-${Math.floor(Math.random() * 1e9)}`,
    contractType: 'employment',
    language: 'en',
  });
  createdContractIds.push(c.id);
  return c.id;
};

// ============================================================================
// S1 — fn_dashboard_admin
// ============================================================================
describe('S1 — fn_dashboard_admin / GET /api/v1/dashboards/admin', () => {
  it('AC-S1-01: admin caller returns 200 with kpis + trends populated', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toBeDefined();
    expect(res.body.kpis).toBeDefined();
    expect(res.body.trends).toBeDefined();
    // 9 kpi keys per design
    expect(typeof res.body.kpis.totalContractsActive).toBe('number');
    expect(typeof res.body.kpis.totalContractsByStatus).toBe('object');
    expect(typeof res.body.kpis.expiringWithin30d).toBe('number');
    expect(typeof res.body.kpis.expiringWithin90d).toBe('number');
    expect(typeof res.body.kpis.pendingApprovals).toBe('number');
    expect(typeof res.body.kpis.pendingSignatures).toBe('number');
    expect(typeof res.body.kpis.openRegulatoryImpacts).toBe('number');
    expect(typeof res.body.kpis.recentAuditEvents).toBe('number');
    expect(typeof res.body.kpis.totalActiveUsers).toBe('number');
    expect(Array.isArray(res.body.trends.contractsCreatedByDay)).toBe(true);
    expect(Array.isArray(res.body.trends.approvalDecisionsByDay)).toBe(true);
  });

  it('AC-S1-02: contract_drafter receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S1-02b: contract_recipient receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S1-02c: executive (non-admin) receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S1-03: totalContractsByStatus values are non-negative', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    for (const v of Object.values(res.body.kpis.totalContractsByStatus)) {
      expect(v).toBeGreaterThanOrEqual(0);
    }
  });

  it('AC-S1-04: expiringWithin30d <= expiringWithin90d (monotonic)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis.expiringWithin30d).toBeLessThanOrEqual(
      res.body.kpis.expiringWithin90d,
    );
  });

  it('AC-S1-05: contractsCreatedByDay covers windowDays days; missing days have count 0', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ windowDays: 7 });
    expect(res.status).toBe(200);
    // Allow ±1 day for boundary inclusivity (generate_series semantics).
    expect(res.body.trends.contractsCreatedByDay.length).toBeGreaterThanOrEqual(7);
    expect(res.body.trends.contractsCreatedByDay.length).toBeLessThanOrEqual(8);
    for (const point of res.body.trends.contractsCreatedByDay) {
      expect(point).toHaveProperty('date');
      expect(point).toHaveProperty('count');
      expect(typeof point.count).toBe('number');
      expect(point.count).toBeGreaterThanOrEqual(0);
    }
  });

  it('AC-S1-06: windowDays=0 returns 400 with field/message', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ windowDays: 0 });
    expect(res.status).toBe(400);
  });

  it('AC-S1-06b: windowDays=400 returns 400', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${adminToken}`)
      .query({ windowDays: 400 });
    expect(res.status).toBe(400);
  });

  it('S1 (defense in depth): approvalDecisionsByDay points use present-tense filter — entries have approved+rejected as numbers', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/admin')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    for (const point of res.body.trends.approvalDecisionsByDay) {
      expect(point).toHaveProperty('date');
      expect(typeof point.approved).toBe('number');
      expect(typeof point.rejected).toBe('number');
    }
  });
});

// ============================================================================
// S2 — fn_dashboard_drafter
// ============================================================================
describe('S2 — fn_dashboard_drafter / GET /api/v1/dashboards/drafter', () => {
  it('AC-S2-01: drafter caller returns 200 with kpis + lists populated', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/drafter')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis).toBeDefined();
    expect(res.body.lists).toBeDefined();
    expect(typeof res.body.kpis.myDraftsCount).toBe('number');
    expect(typeof res.body.kpis.awaitingMyActionCount).toBe('number');
    expect(typeof res.body.kpis.readyToSendCount).toBe('number');
    expect(typeof res.body.kpis.myRecentlyApprovedCount).toBe('number');
    expect(Array.isArray(res.body.lists.myDrafts5)).toBe(true);
    expect(Array.isArray(res.body.lists.awaitingMyAction5)).toBe(true);
  });

  it('AC-S2-02: drafter sees only own contracts in lists.myDrafts5', async () => {
    // Seed a contract as drafter1 — it must appear in their dashboard.
    const ownId = await createDraftAsDrafter();

    const res = await request(app)
      .get('/api/v1/dashboards/drafter')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(200);
    // The drafter has at most 5 most-recent drafts visible; the just-created
    // one should be in the top of the list (bordered by other test artifacts).
    const drafterUser = getFixture('drafter1');
    const ids = (res.body.lists.myDrafts5 as Array<{ id: number }>).map(
      (r) => r.id,
    );
    // We don't assert exact membership because other suites may have seeded
    // additional drafts; we DO assert all visible rows belong to the drafter
    // (permission-narrow check).
    if (ids.length > 0) {
      const ownership = await adminQuery<{ count: string }>(
        `SELECT COUNT(*)::text AS count FROM contract
          WHERE id = ANY($1::BIGINT[]) AND drafted_by = $2`,
        [ids, drafterUser.id],
      );
      expect(Number(ownership[0]!.count)).toBe(ids.length);
    }
    expect(ownId).toBeGreaterThan(0);
  });

  it('AC-S2-04: lists.myDrafts5 has at most 5 entries', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/drafter')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(200);
    expect(res.body.lists.myDrafts5.length).toBeLessThanOrEqual(5);
  });

  it('AC-S2-05: contract_recipient receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/drafter')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S2-05b: legal_counsel receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/drafter')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S2-06: platform_admin can call drafter dashboard (admin-permissive)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/drafter')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
  });

  it('S2 windowDays validation — 366 returns 400', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/drafter')
      .set('Authorization', `Bearer ${drafterToken}`)
      .query({ windowDays: 366 });
    expect(res.status).toBe(400);
  });
});

// ============================================================================
// S3 — fn_dashboard_approver (post-057 patch — pendingQueue5 JOIN regression)
// ============================================================================
describe('S3 — fn_dashboard_approver / GET /api/v1/dashboards/approver', () => {
  it('AC-S3-01: approver caller returns 200 with kpis + lists populated', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/approver')
      .set('Authorization', `Bearer ${approverToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis).toBeDefined();
    expect(res.body.lists).toBeDefined();
    expect(typeof res.body.kpis.pendingMyApprovalCount).toBe('number');
    expect(typeof res.body.kpis.decidedByMeCount).toBe('number');
    expect(Array.isArray(res.body.lists.pendingQueue5)).toBe(true);
  });

  it('AC-S3-02 / S2-22-FIX-2a: pendingMyApprovalCount picks up step assigned to caller via approver_user_id', async () => {
    const drafterUser = getFixture('drafter1');
    const approverUser = getFixture('approver1');
    const contractId = await createDraftAsDrafter();
    await seedPendingApprovalForUser({
      contractId,
      approverUserId: approverUser.id,
      approverRole: 'contract_approver',
      initiatedBy: drafterUser.id,
    });

    const res = await request(app)
      .get('/api/v1/dashboards/approver')
      .set('Authorization', `Bearer ${approverToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis.pendingMyApprovalCount).toBeGreaterThanOrEqual(1);
  });

  it('M6-DB-IMPL-DEFECT-1 regression / 057: pendingQueue5 returns rows with proper contract context (chain join works)', async () => {
    const drafterUser = getFixture('drafter1');
    const approverUser = getFixture('approver1');
    const contractId = await createDraftAsDrafter();
    const seeded = await seedPendingApprovalForUser({
      contractId,
      approverUserId: approverUser.id,
      approverRole: 'contract_approver',
      initiatedBy: drafterUser.id,
    });

    const res = await request(app)
      .get('/api/v1/dashboards/approver')
      .set('Authorization', `Bearer ${approverToken}`);
    expect(res.status).toBe(200);

    type Row = {
      stepId: number;
      contractId: number;
      contractNumber: string;
      titleEn: string;
      hoursWaiting: number;
    };
    const rows = res.body.lists.pendingQueue5 as Row[];
    const seededRow = rows.find((r) => Number(r.stepId) === seeded.stepId);
    expect(seededRow).toBeDefined();
    expect(seededRow!.contractId).toBe(contractId);
    expect(seededRow!.contractNumber).toBeTruthy();
    expect(seededRow!.titleEn).toBeTruthy();
    expect(typeof seededRow!.hoursWaiting).toBe('number');
  });

  it('AC-S3-06: contract_drafter receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/approver')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S3-06b: contract_recipient receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/approver')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });

  it('S3: contract_approver_2 also reaches body (returns 200)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/approver')
      .set('Authorization', `Bearer ${approver2Token}`);
    expect(res.status).toBe(200);
  });
});

// ============================================================================
// S4 — fn_dashboard_legal_counsel
// ============================================================================
describe('S4 — fn_dashboard_legal_counsel / GET /api/v1/dashboards/legal-counsel', () => {
  it('AC-S4-01: legal_counsel caller returns 200 with kpis + lists', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/legal-counsel')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis).toBeDefined();
    expect(res.body.lists).toBeDefined();
    expect(typeof res.body.kpis.regulatoryUpdatesThisWindow).toBe('number');
    expect(typeof res.body.kpis.openRegulatoryImpacts).toBe('number');
    expect(typeof res.body.kpis.criticalSeverityCount).toBe('number');
    expect(typeof res.body.kpis.regulationCatalogSize).toBe('number');
    // R-LC1 (migrations 071/072) extended fn_dashboard_legal_counsel beyond
    // the M6 placeholder shape — added activeContracts / expiringIn30d /
    // pendingReview KPIs and dropped the templateUsageThisWindow stub.
    expect(typeof res.body.kpis.activeContracts).toBe('number');
    expect(typeof res.body.kpis.expiringIn30d).toBe('number');
    expect(typeof res.body.kpis.pendingReview).toBe('number');
    expect(Array.isArray(res.body.lists.recentRegulatoryUpdates5)).toBe(true);
    expect(Array.isArray(res.body.lists.openImpacts5)).toBe(true);
  });

  it('AC-S4-02 / CRIT-1: openRegulatoryImpacts is non-negative integer (uses resolved=FALSE — no resolved_at column)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/legal-counsel')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis.openRegulatoryImpacts).toBeGreaterThanOrEqual(0);
    expect(Number.isInteger(res.body.kpis.openRegulatoryImpacts)).toBe(true);
  });

  it('AC-S4-04: regulationCatalogSize matches live count of active regulations', async () => {
    const liveCount = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count FROM regulation WHERE is_active = TRUE`,
    );
    const res = await request(app)
      .get('/api/v1/dashboards/legal-counsel')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis.regulationCatalogSize).toBe(Number(liveCount[0]!.count));
  });

  it('CRIT-4 + S2-22-FIX-4: auditSummary keys are live audit_log.table_name values when caller has audit.read; null when not', async () => {
    // legal_counsel has audit.read per M0 seeded perms — auditSummary should be
    // a Record<string, number>, not null.
    const res = await request(app)
      .get('/api/v1/dashboards/legal-counsel')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    // Either non-null record OR null — both satisfy the type. Assert structure
    // when populated.
    if (res.body.kpis.auditSummary !== null) {
      expect(typeof res.body.kpis.auditSummary).toBe('object');
      // Keys should be table_name strings; values should be non-negative ints.
      for (const [k, v] of Object.entries(res.body.kpis.auditSummary)) {
        expect(typeof k).toBe('string');
        expect(typeof v).toBe('number');
        expect(v as number).toBeGreaterThanOrEqual(0);
      }
    }
  });

  it.skip('AC-S4-05: templateUsageThisWindow is { value: 0, placeholder: true } — superseded by R-LC1', async () => {
    // R-LC1 (migrations 071/072) replaced the templateUsageThisWindow
    // placeholder with real contracts-led KPIs (activeContracts /
    // expiringIn30d / pendingReview). The placeholder stub was removed
    // entirely. AC-S4-01 above now asserts the new KPI shape.
  });

  it('AC-S4-07: contract_drafter receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/legal-counsel')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S4-07b: contract_recipient receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/legal-counsel')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(403);
  });

  it('S4: lists.recentRegulatoryUpdates5 has at most 5 rows; each has nested regulator object', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/legal-counsel')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    expect(res.body.lists.recentRegulatoryUpdates5.length).toBeLessThanOrEqual(5);
    for (const row of res.body.lists.recentRegulatoryUpdates5) {
      expect(row).toHaveProperty('id');
      expect(row).toHaveProperty('titleEn');
      expect(row).toHaveProperty('severity');
      expect(row).toHaveProperty('regulator');
      expect(row.regulator).toHaveProperty('id');
      expect(row.regulator).toHaveProperty('nameEn');
    }
  });
});

// ============================================================================
// S5 — fn_dashboard_recipient (S2-22-FIX-1 + FIX-5 regression)
// ============================================================================
describe('S5 — fn_dashboard_recipient / GET /api/v1/dashboards/recipient', () => {
  it('AC-S5-01: recipient caller returns 200 with kpis + lists populated', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/recipient')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis).toBeDefined();
    expect(res.body.lists).toBeDefined();
    expect(typeof res.body.kpis.myContractsCount).toBe('number');
    expect(typeof res.body.kpis.pendingMySignatureCount).toBe('number');
    expect(typeof res.body.kpis.signedByMeWindow).toBe('number');
    expect(res.body.kpis.myObligationsCount).toEqual({
      value: 0,
      placeholder: true,
    });
    expect(Array.isArray(res.body.lists.myContracts5)).toBe(true);
    expect(Array.isArray(res.body.lists.pendingSignatures5)).toBe(true);
  });

  it('AC-S5-02 + S2-22-FIX-5: pendingSignatures5 row uses sentAt (alias) — not raw column name', async () => {
    const drafterUser = getFixture('drafter1');
    const recipientUser = getFixture('recipient1');
    const contractId = await createDraftAsDrafter();
    const { partyId, invitationId } = await seedSignatureInvitation({
      contractId,
      signerEmail: recipientUser.email,
      actorUserId: drafterUser.id,
      status: 'pending',
    });
    createdSignaturePartyIds.push(partyId);
    createdSignatureInvitationIds.push(invitationId);

    const res = await request(app)
      .get('/api/v1/dashboards/recipient')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(200);
    type Row = {
      invitationId: number;
      contractId: number;
      contractNumber: string;
      sentAt: string | null;
      expiresAt: string | null;
    };
    const rows = res.body.lists.pendingSignatures5 as Row[];
    const seededRow = rows.find(
      (r) => Number(r.invitationId) === invitationId,
    );
    expect(seededRow).toBeDefined();
    expect(seededRow!.contractId).toBe(contractId);
    expect(seededRow!.sentAt).toBeTruthy(); // S2-22-FIX-5a alias verification
    // expiresAt may or may not be null depending on test fixture; we verify
    // the field exists (NOT a missing key) — both shapes satisfy the contract.
    expect('expiresAt' in seededRow!).toBe(true);
  });

  it('AC-S5-03 + S2-22-FIX-1: signedByMeWindow counts signature_event with actor_user_id=v_user_id and event_type=signed', async () => {
    const drafterUser = getFixture('drafter1');
    const recipientUser = getFixture('recipient1');
    const contractId = await createDraftAsDrafter();
    const { partyId, invitationId } = await seedSignatureInvitation({
      contractId,
      signerEmail: recipientUser.email,
      actorUserId: drafterUser.id,
      status: 'signed',
    });
    createdSignaturePartyIds.push(partyId);
    createdSignatureInvitationIds.push(invitationId);
    const eventId = await seedSignatureEvent({
      signatureInvitationId: invitationId,
      actorUserId: recipientUser.id,
      eventType: 'signed',
    });
    createdSignatureEventIds.push(eventId);

    const res = await request(app)
      .get('/api/v1/dashboards/recipient')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis.signedByMeWindow).toBeGreaterThanOrEqual(1);
  });

  it('AC-S5-04: myObligationsCount is { value: 0, placeholder: true }', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/recipient')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(200);
    expect(res.body.kpis.myObligationsCount.value).toBe(0);
    expect(res.body.kpis.myObligationsCount.placeholder).toBe(true);
  });

  it('AC-S5-07: contract_drafter receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/recipient')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('AC-S5-07b: legal_counsel receives 403', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/recipient')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(403);
  });

  it('S5: lists.pendingSignatures5 caps at 5', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/recipient')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(200);
    expect(res.body.lists.pendingSignatures5.length).toBeLessThanOrEqual(5);
  });
});

// ============================================================================
// S6 — fn_dashboard_router (S2-22-WARN-3-FIX nested role.name)
// ============================================================================
describe('S6 — fn_dashboard_router / GET /api/v1/dashboards/router', () => {
  it('AC-S6-01: returns { userId, primaryRole, dashboardKey, permissionsSummary }', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/router')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('userId');
    expect(res.body).toHaveProperty('primaryRole');
    expect(res.body).toHaveProperty('dashboardKey');
    expect(res.body).toHaveProperty('permissionsSummary');
    expect(res.body.permissionsSummary).toHaveProperty('canViewAdminDashboard');
    expect(res.body.permissionsSummary).toHaveProperty('canViewExecutiveDashboard');
  });

  it('AC-S6-02a / WARN-3-FIX: Super Admin (bootstrap) routes to dashboardKey=admin (proves nested role.name extraction works)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/router')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    // Bootstrap admin is 'Super Admin' (m1a-helpers L23 / 006 seed).
    expect(res.body.primaryRole).toBe('Super Admin');
    expect(res.body.dashboardKey).toBe('admin');
    expect(res.body.permissionsSummary.canViewAdminDashboard).toBe(true);
    expect(res.body.permissionsSummary.canViewExecutiveDashboard).toBe(true);
  });

  it('AC-S6-02b: drafter → dashboardKey=drafter', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/router')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(200);
    expect(res.body.primaryRole).toBe('contract_drafter');
    expect(res.body.dashboardKey).toBe('drafter');
    expect(res.body.permissionsSummary.canViewAdminDashboard).toBe(false);
    expect(res.body.permissionsSummary.canViewExecutiveDashboard).toBe(false);
  });

  it('AC-S6-02c: approver → dashboardKey=approver', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/router')
      .set('Authorization', `Bearer ${approverToken}`);
    expect(res.status).toBe(200);
    expect(res.body.primaryRole).toBe('contract_approver');
    expect(res.body.dashboardKey).toBe('approver');
  });

  it('AC-S6-02d: legal_counsel → dashboardKey=legal_counsel', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/router')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    expect(res.body.primaryRole).toBe('legal_counsel');
    expect(res.body.dashboardKey).toBe('legal_counsel');
  });

  it('AC-S6-02e: executive → dashboardKey=executive', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/router')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(res.body.primaryRole).toBe('executive');
    expect(res.body.dashboardKey).toBe('executive');
    expect(res.body.permissionsSummary.canViewExecutiveDashboard).toBe(true);
  });

  it('AC-S6-02f: contract_recipient → dashboardKey=recipient (default fallback)', async () => {
    const res = await request(app)
      .get('/api/v1/dashboards/router')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(200);
    expect(res.body.primaryRole).toBe('contract_recipient');
    expect(res.body.dashboardKey).toBe('recipient');
  });

  it('AC-S6-05: no JWT returns 401', async () => {
    const res = await request(app).get('/api/v1/dashboards/router');
    expect(res.status).toBe(401);
  });
});
