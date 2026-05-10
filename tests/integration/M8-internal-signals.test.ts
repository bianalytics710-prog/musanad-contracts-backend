/**
 * M8 — internal-signals HTTP integration tests (CR-A2).
 *
 * Covers the 4 M8 endpoints as seen by Express:
 *   POST /api/v1/admin/internal-signals          (ingest, system-only)
 *   GET  /api/v1/admin/internal-signal-kinds     (catalogue, bare-array)
 *   GET  /api/v1/internal-signals                (paginated list)
 *   POST /api/v1/internal-signals/:id/resolve    (resolve, idempotent)
 *
 * Asserts auth (401), permission gating (403 drafter/non-admin), happy
 * paths (200/201), idempotent re-resolve (AC-S5-03), validation errors
 * (400 unknown signalType / 400 missing required field), and the AC-S6-01
 * bare-array shape contract for the kinds endpoint.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  loginAdmin,
  adminQuery,
  closeAdminPool,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  signFixtureToken,
} from '../helpers/m1c-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;
let legalToken: string;
let executiveToken: string;

const RUN_ID = `m8int-${Date.now()}`;
const trackedSignalIds: number[] = [];
let EPC_CONTRACT_ID: number;

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;

  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  legalToken = signFixtureToken('legal_counsel1');
  executiveToken = signFixtureToken('executive1');

  // Sanity — the EPC seed contract is a precondition for the ingest tests.
  const rows = await adminQuery<{ id: string }>(
    `SELECT id::text AS id FROM contract WHERE contract_number = 'CRA2-EPC-2026-001'`,
  );
  expect(rows.length).toBe(1);
  EPC_CONTRACT_ID = Number(rows[0]!.id);

  // Sanity — fixture role names match expectations.
  expect(getFixture('drafter1').roleName).toBe('contract_drafter');
  expect(getFixture('legal_counsel1').roleName).toBe('legal_counsel');
  expect(getFixture('executive1').roleName).toBe('executive');
});

afterAll(async () => {
  if (trackedSignalIds.length > 0) {
    try {
      await adminQuery(
        `DELETE FROM osint_signal WHERE id = ANY($1::BIGINT[])`,
        [trackedSignalIds],
      );
    } catch (err) {
      console.warn('[M8-int-cleanup]', err);
    }
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

// ============================================================================
// Auth gate (401)
// ============================================================================

describe('M8 — auth gate', () => {
  it('POST /api/v1/admin/internal-signals without token → 401', async () => {
    const res = await request(app)
      .post('/api/v1/admin/internal-signals')
      .send({});
    expect(res.status).toBe(401);
  });

  it('GET /api/v1/admin/internal-signal-kinds without token → 401', async () => {
    const res = await request(app).get('/api/v1/admin/internal-signal-kinds');
    expect(res.status).toBe(401);
  });

  it('GET /api/v1/internal-signals without token → 401', async () => {
    const res = await request(app).get('/api/v1/internal-signals');
    expect(res.status).toBe(401);
  });

  it('POST /api/v1/internal-signals/:id/resolve without token → 401', async () => {
    const res = await request(app)
      .post('/api/v1/internal-signals/1/resolve')
      .send({ resolutionKind: 'cleared' });
    expect(res.status).toBe(401);
  });
});

// ============================================================================
// AC-S6-01 — GET /admin/internal-signal-kinds (catalogue, bare-array)
// ============================================================================

describe('M8 GET /admin/internal-signal-kinds — catalogue', () => {
  it('AC-S6-01: Super Admin → 200 with bare array of 8 rows', async () => {
    const res = await request(app)
      .get('/api/v1/admin/internal-signal-kinds')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
    expect(res.body.length).toBe(8);

    // Every row matches the InternalSignalKind shape contract.
    const SEVERITIES = new Set(['informational', 'low', 'medium', 'high', 'critical']);
    for (const row of res.body) {
      expect(typeof row.id).toBe('number');
      expect(typeof row.signalType).toBe('string');
      expect(typeof row.displayName).toBe('string');
      expect(typeof row.displayNameAr).toBe('string');
      expect(row.parameterSchema).toBeDefined();
      expect(Array.isArray(row.parameterSchema.required)).toBe(true);
      expect(SEVERITIES.has(row.defaultSeverity)).toBe(true);
      expect(row.isActive).toBe(true);
    }

    // The 8 expected signalType values must all be present.
    const types = new Set<string>(res.body.map((r: any) => r.signalType));
    for (const t of [
      'milestone_slippage', 'sla_breach', 'payment_delay', 'invoice_dispute',
      'vendor_incident', 'ics_incident', 'icv_status_change', 'certificate_expiry',
    ]) {
      expect(types.has(t)).toBe(true);
    }
  });

  it('AC-S6-05: drafter (no internal_signal.read) → 403', async () => {
    const res = await request(app)
      .get('/api/v1/admin/internal-signal-kinds')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('legal_counsel (has internal_signal.read) → 200', async () => {
    const res = await request(app)
      .get('/api/v1/admin/internal-signal-kinds')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
    expect(res.body.length).toBe(8);
  });
});

// ============================================================================
// AC-S2-01 / AC-S2-02 / AC-S2-03 / AC-S2-04 — POST /admin/internal-signals (ingest)
// ============================================================================

describe('M8 POST /admin/internal-signals — ingest', () => {
  it('AC-S2-01: Super Admin happy path → 201 with { signalId, inserted=true, signalKindSubtype }', async () => {
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 3).toISOString();
    const res = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        signalType: 'milestone_slippage',
        contractId: EPC_CONTRACT_ID,
        milestoneRef: `M-${RUN_ID}-int01`,
        observedAt,
      });
    expect(res.status).toBe(201);
    expect(typeof res.body.signalId).toBe('number');
    expect(res.body.inserted).toBe(true);
    expect(res.body.dedupHashHit).toBe(false);
    expect(res.body.signalKindSubtype).toBe('milestone_slippage');
    trackedSignalIds.push(res.body.signalId);
  });

  it('AC-S2-02: re-posting identical body → 201 with inserted=false + same signalId', async () => {
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 4).toISOString();
    const body = {
      signalType: 'milestone_slippage',
      contractId: EPC_CONTRACT_ID,
      milestoneRef: `M-${RUN_ID}-int-dedup`,
      observedAt,
    };
    const r1 = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${adminToken}`)
      .send(body);
    expect(r1.status).toBe(201);
    expect(r1.body.inserted).toBe(true);
    trackedSignalIds.push(r1.body.signalId);

    const r2 = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${adminToken}`)
      .send(body);
    expect(r2.status).toBe(201);
    expect(r2.body.inserted).toBe(false);
    expect(r2.body.dedupHashHit).toBe(true);
    expect(r2.body.signalId).toBe(r1.body.signalId);
  });

  it('AC-S2-03: unknown signalType → 400 VALIDATION_ERROR', async () => {
    const observedAt = new Date().toISOString();
    const res = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        signalType: 'completely_made_up_type',
        contractId: EPC_CONTRACT_ID,
        observedAt,
      });
    expect(res.status).toBe(400);
  });

  it('AC-S2-04: missing required field (milestoneRef on milestone_slippage) → 400', async () => {
    const observedAt = new Date().toISOString();
    const res = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        signalType: 'milestone_slippage',
        contractId: EPC_CONTRACT_ID,
        observedAt,
        // milestoneRef intentionally omitted
      });
    expect(res.status).toBe(400);
  });

  it('AC-S2-06: drafter (lacks internal_signal.ingest) → 403', async () => {
    const observedAt = new Date().toISOString();
    const res = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        signalType: 'milestone_slippage',
        contractId: EPC_CONTRACT_ID,
        milestoneRef: `M-${RUN_ID}-deny`,
        observedAt,
      });
    expect(res.status).toBe(403);
  });

  it('legal_counsel (has read but NOT ingest) → 403', async () => {
    const observedAt = new Date().toISOString();
    const res = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        signalType: 'milestone_slippage',
        contractId: EPC_CONTRACT_ID,
        milestoneRef: `M-${RUN_ID}-deny-legal`,
        observedAt,
      });
    expect(res.status).toBe(403);
  });
});

// ============================================================================
// AC-S4-01 / AC-S4-02 / AC-S4-03 — GET /internal-signals (paginated list)
// ============================================================================

describe('M8 GET /internal-signals — paginated list', () => {
  it('AC-S4-01: Super Admin → 200 with paginated envelope { data, pagination }', async () => {
    const res = await request(app)
      .get('/api/v1/internal-signals?limit=50')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.pagination).toBeDefined();
    expect(typeof res.body.pagination.total).toBe('number');
    expect(typeof res.body.pagination.page).toBe('number');
    expect(typeof res.body.pagination.totalPages).toBe('number');
    // Every row must have kind='internal'.
    for (const row of res.body.data) {
      expect(row.kind).toBe('internal');
    }
  });

  it('AC-S4-02: ?signalType=milestone_slippage filters to milestone_slippage rows', async () => {
    const res = await request(app)
      .get('/api/v1/internal-signals?signalType=milestone_slippage&limit=100')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    // Seed pack inserts 4 milestone_slippage rows on EPC contract within
    // the last 180 days; floor: 4.
    expect(res.body.data.length).toBeGreaterThanOrEqual(4);
    for (const row of res.body.data) {
      expect(row.signalType).toBe('milestone_slippage');
      expect(row.kind).toBe('internal');
    }
  });

  it('AC-S4-03: drafter (no internal_signal.read) → 403', async () => {
    const res = await request(app)
      .get('/api/v1/internal-signals')
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(403);
  });

  it('executive (has internal_signal.read) → 200', async () => {
    const res = await request(app)
      .get('/api/v1/internal-signals?limit=10')
      .set('Authorization', `Bearer ${executiveToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
  });
});

// ============================================================================
// AC-S5-01 / AC-S5-03 / AC-S5-06 — POST /internal-signals/:id/resolve
// ============================================================================

describe('M8 POST /internal-signals/:id/resolve — resolution', () => {
  it('AC-S5-01: Super Admin resolves a sla_breach signal → 200 with { signalId, resolvedAt, resolvedBy } and idempotent=false on first call', async () => {
    // Mint a fresh sla_breach so this test is independent.
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 8).toISOString();
    const ingest = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        signalType: 'sla_breach',
        contractId: EPC_CONTRACT_ID,
        observedAt,
      });
    expect(ingest.status).toBe(201);
    const sigId = ingest.body.signalId;
    trackedSignalIds.push(sigId);

    const res = await request(app)
      .post(`/api/v1/internal-signals/${sigId}/resolve`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ resolutionKind: 'cleared', resolutionNote: 'AC-S5-01 integration' });
    expect(res.status).toBe(200);
    expect(res.body.signalId).toBe(sigId);
    expect(typeof res.body.resolvedAt).toBe('string');
    expect(typeof res.body.resolvedBy).toBe('number');
    expect(res.body.resolutionKind).toBe('cleared');
    expect(res.body.idempotent).toBe(false);

    // AC-S5-03: re-resolve → 200 with idempotent=true, same resolvedAt
    const res2 = await request(app)
      .post(`/api/v1/internal-signals/${sigId}/resolve`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ resolutionKind: 'cleared', resolutionNote: 'second call' });
    expect(res2.status).toBe(200);
    expect(res2.body.idempotent).toBe(true);
    expect(res2.body.resolvedAt).toBe(res.body.resolvedAt);
  });

  it('AC-S5-06: signal id not found → 404', async () => {
    const res = await request(app)
      .post('/api/v1/internal-signals/99999999/resolve')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ resolutionKind: 'cleared' });
    expect(res.status).toBe(404);
  });

  it('Validation: invalid resolutionKind → 400', async () => {
    // Ingest a fresh signal first.
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 16).toISOString();
    const ingest = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ signalType: 'sla_breach', contractId: EPC_CONTRACT_ID, observedAt });
    expect(ingest.status).toBe(201);
    trackedSignalIds.push(ingest.body.signalId);

    const res = await request(app)
      .post(`/api/v1/internal-signals/${ingest.body.signalId}/resolve`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ resolutionKind: 'not_a_real_kind' });
    expect(res.status).toBe(400);
  });

  it('drafter cannot resolve → 403', async () => {
    const observedAt = new Date(Date.now() - 1000 * 60 * 60 * 24 * 19).toISOString();
    const ingest = await request(app)
      .post('/api/v1/admin/internal-signals')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ signalType: 'sla_breach', contractId: EPC_CONTRACT_ID, observedAt });
    expect(ingest.status).toBe(201);
    trackedSignalIds.push(ingest.body.signalId);

    const res = await request(app)
      .post(`/api/v1/internal-signals/${ingest.body.signalId}/resolve`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ resolutionKind: 'cleared' });
    expect(res.status).toBe(403);
  });
});
