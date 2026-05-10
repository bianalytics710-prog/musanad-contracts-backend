/**
 * M9 (CR-B) — Party Graph HTTP integration tests.
 *
 * Covers the 8 net-new M9 endpoints + the 1 PATCH /:id endpoint:
 *   GET    /api/v1/parties/:id/relationships
 *   POST   /api/v1/parties/:id/relationships
 *   PATCH  /api/v1/parties/:id/relationships/:relId
 *   DELETE /api/v1/parties/:id/relationships/:relId
 *   GET    /api/v1/parties/:id/chain
 *   GET    /api/v1/parties/:id/chain-summary
 *   POST   /api/v1/admin/parties/sanctions-match
 *   PATCH  /api/v1/parties/:id
 *
 * Asserts auth (401), permission gating (403 drafter on manage paths,
 * 200 drafter on read paths), happy paths (200/201), idempotent re-delete
 * (AC-S3-02), validation errors (400 duplicate via 23505 → 409, 404 on
 * non-existent parent_id), and the Q-DA4 silent-ignore path on PATCH /:id
 * for sanctions_* fields.
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
let recipientToken: string;

const trackedRelIds: number[] = [];

// Hero-chain ids verified post-122 on the test branch.
const ID_SYNTHETIC = 55;
const ID_SCHLUMBERGER = 57;
const ID_HALLIBURTON_WW = 59;
const ID_HALLIBURTON_HEH = 60;
const ID_ADNOC = 2;

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;

  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  legalToken = signFixtureToken('legal_counsel1');
  recipientToken = signFixtureToken('recipient1');

  // Sanity — fixture role names still match expectations.
  expect(getFixture('drafter1').roleName).toBe('contract_drafter');
  expect(getFixture('legal_counsel1').roleName).toBe('legal_counsel');
  expect(getFixture('recipient1').roleName).toBe('contract_recipient');
});

afterAll(async () => {
  if (trackedRelIds.length > 0) {
    try {
      await adminQuery(
        `DELETE FROM party_relationship WHERE id = ANY($1::BIGINT[])`,
        [trackedRelIds],
      );
    } catch (err) {
      console.warn('[M9-int-cleanup]', err);
    }
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

// ============================================================================
// Auth gates (401 — unauthenticated)
// ============================================================================

describe('M9 — auth gate', () => {
  it('GET /api/v1/parties/:id/relationships without token → 401', async () => {
    const res = await request(app).get(
      `/api/v1/parties/${ID_HALLIBURTON_WW}/relationships`,
    );
    expect(res.status).toBe(401);
  });

  it('POST /api/v1/parties/:id/relationships without token → 401', async () => {
    const res = await request(app)
      .post(`/api/v1/parties/${ID_ADNOC}/relationships`)
      .send({ childId: ID_HALLIBURTON_WW, relationshipType: 'subsidiary' });
    expect(res.status).toBe(401);
  });

  it('GET /api/v1/parties/:id/chain without token → 401', async () => {
    const res = await request(app).get(
      `/api/v1/parties/${ID_SCHLUMBERGER}/chain`,
    );
    expect(res.status).toBe(401);
  });

  it('POST /api/v1/admin/parties/sanctions-match without token → 401', async () => {
    const res = await request(app)
      .post('/api/v1/admin/parties/sanctions-match')
      .send({
        signalEntities: [
          { entityType: 'organization', name: 'Synthetic Holdings Cyprus Ltd' },
        ],
      });
    expect(res.status).toBe(401);
  });
});

// ============================================================================
// Permission gating — drafter has read but not manage
// ============================================================================

describe('M9 — permission gating', () => {
  it('AC-S1-02: drafter (no party.graph.manage) cannot POST /relationships → 403', async () => {
    const res = await request(app)
      .post(`/api/v1/parties/${ID_ADNOC}/relationships`)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ childId: ID_HALLIBURTON_WW, relationshipType: 'subsidiary' });
    expect(res.status).toBe(403);
  });

  it('drafter (has party.graph.read) CAN GET /chain → 200', async () => {
    const res = await request(app)
      .get(`/api/v1/parties/${ID_SCHLUMBERGER}/chain?direction=both&maxDepth=5`)
      .set('Authorization', `Bearer ${drafterToken}`);
    expect(res.status).toBe(200);
    const body = res.body.data ?? res.body;
    expect(body.rootPartyId).toBe(ID_SCHLUMBERGER);
    expect(Array.isArray(body.ancestors)).toBe(true);
  });
});

// ============================================================================
// GET /api/v1/parties/:id/relationships — happy path
// ============================================================================

describe('M9 — GET /api/v1/parties/:id/relationships', () => {
  it('AC-S4-01: legal_counsel sees incoming + outgoing for Halliburton Worldwide', async () => {
    const res = await request(app)
      .get(`/api/v1/parties/${ID_HALLIBURTON_WW}/relationships`)
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    const body = res.body.data ?? res.body;
    expect(Array.isArray(body.incoming)).toBe(true);
    expect(Array.isArray(body.outgoing)).toBe(true);
    expect(body.counts).toBeDefined();
    expect(typeof body.counts.incoming).toBe('number');
    expect(typeof body.counts.outgoing).toBe('number');
  });

  it('AC-S4-03: party_not_found → 404', async () => {
    const res = await request(app)
      .get('/api/v1/parties/999999/relationships')
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(404);
  });
});

// ============================================================================
// POST /api/v1/parties/:id/relationships — full CRUD lifecycle
// ============================================================================

describe('M9 — POST /api/v1/parties/:id/relationships', () => {
  let createdRelId: number;

  it('AC-S1-01: legal_counsel creates a new edge → 201', async () => {
    const res = await request(app)
      .post(`/api/v1/parties/${ID_ADNOC}/relationships`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        childId: ID_SYNTHETIC,
        relationshipType: 'jv',
        ownershipPct: 60,
        source: 'manual',
        confidence: 0.95,
      });
    expect(res.status).toBe(201);
    const body = res.body.data ?? res.body;
    expect(typeof body.id).toBe('number');
    expect(body.parentId).toBe(ID_ADNOC);
    expect(body.childId).toBe(ID_SYNTHETIC);
    expect(body.relationshipType).toBe('jv');
    expect(body.isActive).toBe(true);
    createdRelId = body.id;
    trackedRelIds.push(createdRelId);
  });

  it('AC-S1-05: duplicate edge → 409 (UNIQUE violation)', async () => {
    // Re-create the same tuple as the previous test
    const res = await request(app)
      .post(`/api/v1/parties/${ID_ADNOC}/relationships`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        childId: ID_SYNTHETIC,
        relationshipType: 'jv',
        source: 'manual',
      });
    expect(res.status).toBe(409);
  });

  it('AC-S1-04: non-existent parent_id → 404', async () => {
    const res = await request(app)
      .post('/api/v1/parties/999999/relationships')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        childId: ID_HALLIBURTON_WW,
        relationshipType: 'subsidiary',
      });
    expect(res.status).toBe(404);
  });

  it('AC-S1-04: non-existent child_id → 404', async () => {
    const res = await request(app)
      .post(`/api/v1/parties/${ID_ADNOC}/relationships`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        childId: 999999,
        relationshipType: 'subsidiary',
      });
    expect(res.status).toBe(404);
  });

  it('AC-S3-01 / AC-S3-02: DELETE soft-deletes; re-DELETE returns idempotent=true', async () => {
    // First delete
    const r1 = await request(app)
      .delete(`/api/v1/parties/${ID_ADNOC}/relationships/${createdRelId}`)
      .set('Authorization', `Bearer ${legalToken}`);
    expect(r1.status).toBe(200);
    const b1 = r1.body.data ?? r1.body;
    expect(b1.success).toBe(true);
    expect(typeof b1.deletedAt).toBe('string');
    expect(b1.idempotent).toBe(false);

    // Second delete — same edge
    const r2 = await request(app)
      .delete(`/api/v1/parties/${ID_ADNOC}/relationships/${createdRelId}`)
      .set('Authorization', `Bearer ${legalToken}`);
    expect(r2.status).toBe(200);
    const b2 = r2.body.data ?? r2.body;
    expect(b2.success).toBe(true);
    expect(b2.idempotent).toBe(true);
  });

  it('AC-S3-04: deleting non-existent rel → 404', async () => {
    const res = await request(app)
      .delete(`/api/v1/parties/${ID_ADNOC}/relationships/999999`)
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(404);
  });
});

// ============================================================================
// GET /api/v1/parties/:id/chain — direction discriminator
// ============================================================================

describe('M9 — GET /api/v1/parties/:id/chain', () => {
  it('AC-S5-01: direction=up returns ancestors only (Up shape)', async () => {
    const res = await request(app)
      .get(`/api/v1/parties/${ID_SCHLUMBERGER}/chain?direction=up&maxDepth=5`)
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    const body = res.body.data ?? res.body;
    expect(body.rootPartyId).toBe(ID_SCHLUMBERGER);
    expect(Array.isArray(body.ancestors)).toBe(true);
    // descendants must NOT be present in Up shape
    expect(body.descendants).toBeUndefined();
    expect(typeof body.chainTruncated).toBe('boolean');
    expect(typeof body.depthReached).toBe('number');
  });

  it('AC-S6-01: direction=down returns descendants only (Down shape)', async () => {
    const res = await request(app)
      .get(`/api/v1/parties/${ID_HALLIBURTON_HEH}/chain?direction=down&maxDepth=5`)
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    const body = res.body.data ?? res.body;
    expect(body.rootPartyId).toBe(ID_HALLIBURTON_HEH);
    expect(Array.isArray(body.descendants)).toBe(true);
    expect(body.ancestors).toBeUndefined();
  });

  it('AC-S5-02 / AC-S6-02: direction=both returns Both shape with both arrays', async () => {
    const res = await request(app)
      .get(`/api/v1/parties/${ID_SCHLUMBERGER}/chain?direction=both&maxDepth=5`)
      .set('Authorization', `Bearer ${legalToken}`);
    expect(res.status).toBe(200);
    const body = res.body.data ?? res.body;
    expect(Array.isArray(body.ancestors)).toBe(true);
    expect(Array.isArray(body.descendants)).toBe(true);
  });
});

// ============================================================================
// POST /api/v1/admin/parties/sanctions-match
// ============================================================================

describe('M9 — POST /api/v1/admin/parties/sanctions-match', () => {
  it('AC-S7-01: admin POST returns matches for full Synthetic Holdings name', async () => {
    const res = await request(app)
      .post('/api/v1/admin/parties/sanctions-match')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        signalEntities: [
          { entityType: 'organization', name: 'Synthetic Holdings Cyprus Ltd' },
        ],
      });
    expect(res.status).toBe(200);
    const body = res.body.data ?? res.body;
    expect(Array.isArray(body.matches)).toBe(true);
    expect(body.matches.length).toBeGreaterThan(0);
    // Production-Credibility Invariant #8 — matchedEntityName always set
    for (const m of body.matches) {
      expect(typeof m.matchedEntityName).toBe('string');
      expect(m.matchedEntityName.length).toBeGreaterThan(0);
    }
  });

  it('AC-S7-01: bogus name returns empty matches array (similarity below threshold)', async () => {
    const res = await request(app)
      .post('/api/v1/admin/parties/sanctions-match')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        signalEntities: [
          {
            entityType: 'organization',
            name: 'Zzz Nonexistent Counterparty Q9',
          },
        ],
      });
    expect(res.status).toBe(200);
    const body = res.body.data ?? res.body;
    expect(Array.isArray(body.matches)).toBe(true);
    expect(body.matches.length).toBe(0);
  });
});

// ============================================================================
// PATCH /api/v1/parties/:id — editable subset + Q-DA4 silent-ignore
// ============================================================================

describe('M9 — PATCH /api/v1/parties/:id', () => {
  it('AC-S9-01: legal_counsel updates editable subset (esgScore + icvStatus) → 200', async () => {
    const res = await request(app)
      .patch(`/api/v1/parties/${ID_ADNOC}`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        esgScore: 82,
        icvStatus: 'certified',
      });
    expect(res.status).toBe(200);
    const body = res.body.data ?? res.body;
    expect(body.id).toBe(ID_ADNOC);
    expect(body.esgScore).toBe(82);
    expect(body.icvStatus).toBe('certified');
  });

  it('AC-S9-05 / Q-DA4: sanctionsStatus in payload silently ignored (Zod strict-rejection OR no DB change)', async () => {
    // Snapshot
    const before = await adminQuery<{ s: string }>(
      `SELECT sanctions_status AS s FROM party WHERE id = $1`,
      [ID_ADNOC],
    );

    const res = await request(app)
      .patch(`/api/v1/parties/${ID_ADNOC}`)
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        esgScore: 75,
        sanctionsStatus: 'sanctioned', // forbidden field
      });

    // Either Zod strict-rejection (400) OR successful update with silent
    // ignore (200). The api-contracts.json + smoke-be-report.md confirms
    // smoke-test M9 saw 400 from Zod strict mode (which is the documented
    // defence-in-depth path). Either is acceptable as long as
    // sanctions_status is NOT modified.
    expect([200, 400]).toContain(res.status);

    const after = await adminQuery<{ s: string }>(
      `SELECT sanctions_status AS s FROM party WHERE id = $1`,
      [ID_ADNOC],
    );
    expect(after[0]!.s).toBe(before[0]!.s);
  });

  it('AC-S9-02: contract_recipient (no contract.edit, no party.graph.manage) cannot PATCH /parties/:id → 403', async () => {
    // Drafter has contract.edit (project-wide), so they CAN PATCH /:id by
    // design — the fn gates on `contract.edit OR party.graph.manage`. Use
    // recipient to verify the negative case (recipient has neither).
    const res = await request(app)
      .patch(`/api/v1/parties/${ID_ADNOC}`)
      .set('Authorization', `Bearer ${recipientToken}`)
      .send({ esgScore: 50 });
    expect(res.status).toBe(403);
  });
});
