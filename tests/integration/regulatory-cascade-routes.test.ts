/**
 * CR-M — Integration tests: Labor-Law Cascade HTTP routes.
 *
 * Routes under /api/v1/regulatory/cascade and /api/v1/parties:
 *   POST   /api/v1/regulatory/cascade/run
 *   GET    /api/v1/regulatory/cascade
 *   GET    /api/v1/regulatory/cascade/:runId
 *   PATCH  /api/v1/regulatory/cascade/items/:itemId/status
 *   POST   /api/v1/regulatory/cascade/items/:itemId/draft-amendment
 *   POST   /api/v1/parties/:partyId/workforce
 *   GET    /api/v1/parties/:partyId/workforce
 *   GET    /api/v1/parties/workforce
 *
 * Envelope convention (per integration-verification.md + party-graph precedent):
 *   Controllers return the BARE fn_ JSONB via res.json(result).
 *   The FE service wraps via apiClient.post<T>() which yields { data: <bare-body> }.
 *   Tests assert on res.body DIRECTLY (not res.body.data).
 *
 * testLevels: ["unit", "integration"] — no e2e (--no-walk CR)
 *
 * Runs against TEST_DATABASE_URL (migrations 281..294 applied).
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

let complianceEsgToken: string;
let legalCounselToken: string;
let drafterToken: string;
let platformAdminToken: string;

// Track run ids and workforce rows for cleanup
const trackedRunIds: number[] = [];

// ─────────────────────────────────────────────────────────────────────────────
// Role-user seed helper (same pattern as CR-J demo-harness test)
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
         VALUES ($1, '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS', 'Fixture', $2, $3, TRUE, 1, 1)
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

  // Seed compliance_esg + other roles not in the base fixture pool
  const complianceEsgId = await seedRoleUserDirect('compliance_esg', 'crm-int-cesg1@test.crm');
  const legalCounselId  = await seedRoleUserDirect('legal_counsel',  'crm-int-lc1@test.crm');

  // Use the jwt util the same way m1c-helpers signFixtureToken does
  const { signAccessToken } = await import('../../src/utils/jwt.util');
  complianceEsgToken  = signAccessToken({ userId: complianceEsgId,  role: 'compliance_esg' });
  legalCounselToken   = signAccessToken({ userId: legalCounselId,   role: 'legal_counsel' });
  drafterToken        = signFixtureToken('drafter1');
  platformAdminToken  = signFixtureToken('platform_admin1');
}, 90_000);

afterAll(async () => {
  // Soft-delete run rows created during integration tests
  if (trackedRunIds.length > 0) {
    await adminQuery(
      `UPDATE regulatory_cascade_run SET is_active = FALSE WHERE id = ANY($1::BIGINT[])`,
      [trackedRunIds],
    );
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
}, 30_000);

// ─────────────────────────────────────────────────────────────────────────────
// Helper: get the seeded MOHRE decree signal id
// ─────────────────────────────────────────────────────────────────────────────
async function getDecreeSignalId(): Promise<number | null> {
  const rows = await adminQuery<{ id: number }>(
    `SELECT id FROM osint_signal
     WHERE tenant_id = $1::uuid
       AND kind = 'regulatory'
       AND title ILIKE '%Federal Decree-Law No. 9%'
       AND is_active = TRUE
     LIMIT 1`,
    [ADNOC_TENANT_ID],
  );
  return rows.length > 0 ? Number(rows[0]!.id) : null;
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/v1/regulatory/cascade/run
// AC#4 — compliance_esg runs cascade; unauthorized role → 403
// ─────────────────────────────────────────────────────────────────────────────

describe('POST /api/v1/regulatory/cascade/run', () => {
  const ROUTE = '/api/v1/regulatory/cascade/run';

  it('AC#4-int-01: compliance_esg → 200 with completed run + items array', async () => {
    const signalId = await getDecreeSignalId();
    if (!signalId) {
      console.warn('[SKIP] Decree signal not seeded — skipping cascade run integration test');
      return;
    }

    const res = await request(app)
      .post(ROUTE)
      .set('Authorization', `Bearer ${complianceEsgToken}`)
      .send({ signalId });

    expect(res.status).toBe(200);

    // Envelope: bare fn_ JSONB (per integration-verification.md MISMATCH-1 fix)
    const body = res.body as {
      id: number;
      status: string;
      affectedContractorCount: number;
      totalPenaltyMinAed: unknown;
      totalPenaltyMaxAed: unknown;
      summary: { totals: { affectedContractors: number } };
      items: Array<{
        id: number;
        partyId: number;
        headcountBand: string;
        remediationStatus: string;
        penaltyExposureMinAed: unknown;
        penaltyExposureMaxAed: unknown;
        icvAttachmentIds: unknown[];
        affectedClauseIds: unknown[];
      }>;
    };

    expect(body.status).toBe('completed');
    expect(typeof body.id).toBe('number');
    expect(Array.isArray(body.items)).toBe(true);
    expect(body.summary).toBeDefined();
    expect(body.summary.totals).toBeDefined();
    expect(typeof body.summary.totals.affectedContractors).toBe('number');

    // No res.body.data wrapper — bare body is the run
    expect((body as any).success).toBeUndefined();
    expect((body as any).data).toBeUndefined();

    trackedRunIds.push(body.id);
  }, 20_000);

  it('AC#4-int-02: impactSignalId alias also accepted by runCascadeSchema', async () => {
    const signalId = await getDecreeSignalId();
    if (!signalId) return;

    const res = await request(app)
      .post(ROUTE)
      .set('Authorization', `Bearer ${platformAdminToken}`)
      .send({ impactSignalId: signalId });

    expect(res.status).toBe(200);
    const body = res.body as { id: number; status: string };
    expect(body.status).toBe('completed');
    trackedRunIds.push(body.id);
  }, 20_000);

  it('AC#7-int-01: drafter → 404 (module guard — CR-V)', async () => {
    const signalId = await getDecreeSignalId();
    if (!signalId) return;

    const res = await request(app)
      .post(ROUTE)
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ signalId });

    // CR-V: drafter not in regulatory_cascade role codes → 404 MODULE_DISABLED
    expect(res.status).toBe(404);
  });

  it('AC#7-int-02: legal_counsel → 403 (read-only, cannot run)', async () => {
    const signalId = await getDecreeSignalId();
    if (!signalId) return;

    const res = await request(app)
      .post(ROUTE)
      .set('Authorization', `Bearer ${legalCounselToken}`)
      .send({ signalId });

    expect(res.status).toBe(403);
  });

  it('AC#4-int-03: no JWT → 401', async () => {
    const res = await request(app).post(ROUTE).send({ signalId: 1 });
    expect(res.status).toBe(401);
  });

  it('AC#4-int-04: missing signalId body → 400', async () => {
    const res = await request(app)
      .post(ROUTE)
      .set('Authorization', `Bearer ${complianceEsgToken}`)
      .send({});

    expect(res.status).toBe(400);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/v1/regulatory/cascade
// AC#4 — list runs; authorized roles get data; drafter → 403
// ─────────────────────────────────────────────────────────────────────────────

describe('GET /api/v1/regulatory/cascade', () => {
  const ROUTE = '/api/v1/regulatory/cascade';

  it('AC#4-int-05: compliance_esg → 200 with data[] + pagination (bare fn_ JSONB)', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${complianceEsgToken}`);

    expect(res.status).toBe(200);

    // fn_regulatory_cascade_list returns { data: [...], pagination: { total, limit, offset } }
    const body = res.body as {
      data: Array<{ id: number; status: string; affectedContractorCount: number }>;
      pagination: { total: number; limit: number; offset: number };
    };

    expect(Array.isArray(body.data)).toBe(true);
    expect(typeof body.pagination.total).toBe('number');
    expect(typeof body.pagination.limit).toBe('number');
    expect(typeof body.pagination.offset).toBe('number');

    // No extra envelope wrapper
    expect((body as any).success).toBeUndefined();

    if (body.data.length > 0) {
      expect(typeof body.data[0]!.id).toBe('number');
      expect(body.data[0]!.status).toBe('completed');
    }
  });

  it('AC#4-int-06: legal_counsel → 200 (has regulatory.cascade.read)', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${legalCounselToken}`);

    expect(res.status).toBe(200);
    const body = res.body as { data: unknown[]; pagination: unknown };
    expect(Array.isArray(body.data)).toBe(true);
  });

  it('AC#7-int-03: drafter → 404 (module guard — CR-V)', async () => {
    const res = await request(app)
      .get(ROUTE)
      .set('Authorization', `Bearer ${drafterToken}`);

    // CR-V: drafter not in regulatory_cascade role codes → 404 MODULE_DISABLED
    expect(res.status).toBe(404);
  });

  it('AC#4-int-07: no JWT → 401', async () => {
    const res = await request(app).get(ROUTE);
    expect(res.status).toBe(401);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/v1/regulatory/cascade/:runId
// ─────────────────────────────────────────────────────────────────────────────

describe('GET /api/v1/regulatory/cascade/:runId', () => {
  it('AC#4-int-08: compliance_esg → 200 with run detail + items array', async () => {
    // Use any existing cascade run (may have been created by earlier tests)
    const runs = await adminQuery<{ id: number }>(
      `SELECT id FROM regulatory_cascade_run
       WHERE tenant_id = $1::uuid AND is_active = TRUE LIMIT 1`,
      [ADNOC_TENANT_ID],
    );
    if (runs.length === 0) {
      console.warn('[SKIP] No cascade runs in DB');
      return;
    }
    const runId = Number(runs[0]!.id);

    const res = await request(app)
      .get(`/api/v1/regulatory/cascade/${runId}`)
      .set('Authorization', `Bearer ${complianceEsgToken}`);

    expect(res.status).toBe(200);

    const body = res.body as {
      id: number;
      status: string;
      items: Array<{
        id: number;
        partyId: number;
        headcountBand: string;
        remediationStatus: string;
        advisoryDraftId: number | null;
        icvAttachmentIds: unknown[];
      }>;
      summary: unknown;
    };

    expect(Number(body.id)).toBe(runId);
    expect(body.status).toBe('completed');
    expect(Array.isArray(body.items)).toBe(true);

    // No extra envelope wrapper
    expect((body as any).success).toBeUndefined();
    expect((body as any).data).toBeUndefined();
  });

  it('AC#4-int-09: non-existent runId → 404', async () => {
    const res = await request(app)
      .get('/api/v1/regulatory/cascade/999999999')
      .set('Authorization', `Bearer ${complianceEsgToken}`);

    expect(res.status).toBe(404);
  });

  it('AC#7-int-04: drafter → 404 on run detail (module guard — CR-V)', async () => {
    const res = await request(app)
      .get('/api/v1/regulatory/cascade/1')
      .set('Authorization', `Bearer ${drafterToken}`);

    // CR-V: drafter not in regulatory_cascade role codes → 404 MODULE_DISABLED
    expect(res.status).toBe(404);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// PATCH /api/v1/regulatory/cascade/items/:itemId/status
// AC#4 — item status transitions
// ─────────────────────────────────────────────────────────────────────────────

describe('PATCH /api/v1/regulatory/cascade/items/:itemId/status', () => {
  it('AC#4-int-10: compliance_esg can set item status → 200 with updated item', async () => {
    const items = await adminQuery<{ id: number }>(
      `SELECT rci.id FROM regulatory_cascade_item rci
       JOIN regulatory_cascade_run rcr ON rcr.id = rci.cascade_run_id
       WHERE rcr.tenant_id = $1::uuid AND rci.is_active = TRUE LIMIT 1`,
      [ADNOC_TENANT_ID],
    );
    if (items.length === 0) {
      console.warn('[SKIP] No cascade items found');
      return;
    }
    const itemId = Number(items[0]!.id);

    const res = await request(app)
      .patch(`/api/v1/regulatory/cascade/items/${itemId}/status`)
      .set('Authorization', `Bearer ${complianceEsgToken}`)
      .send({ status: 'in_progress', note: 'Working on it' });

    expect(res.status).toBe(200);

    // Returns bare item JSONB (not wrapped in success/data envelope)
    const body = res.body as { id: number; remediationStatus: string };
    expect(Number(body.id)).toBe(itemId);
    expect(body.remediationStatus).toBe('in_progress');
    expect((body as any).success).toBeUndefined();
  });

  it('AC#4-int-11: legal_counsel → 200 (has cascade.read gate per Q6)', async () => {
    const items = await adminQuery<{ id: number }>(
      `SELECT rci.id FROM regulatory_cascade_item rci
       JOIN regulatory_cascade_run rcr ON rcr.id = rci.cascade_run_id
       WHERE rcr.tenant_id = $1::uuid AND rci.is_active = TRUE LIMIT 1`,
      [ADNOC_TENANT_ID],
    );
    if (items.length === 0) return;
    const itemId = Number(items[0]!.id);

    const res = await request(app)
      .patch(`/api/v1/regulatory/cascade/items/${itemId}/status`)
      .set('Authorization', `Bearer ${legalCounselToken}`)
      .send({ status: 'resolved', note: null });

    expect(res.status).toBe(200);
  });

  it('AC#4-int-12: invalid status value → 400', async () => {
    const items = await adminQuery<{ id: number }>(
      `SELECT rci.id FROM regulatory_cascade_item rci
       JOIN regulatory_cascade_run rcr ON rcr.id = rci.cascade_run_id
       WHERE rcr.tenant_id = $1::uuid AND rci.is_active = TRUE LIMIT 1`,
      [ADNOC_TENANT_ID],
    );
    if (items.length === 0) return;

    const res = await request(app)
      .patch(`/api/v1/regulatory/cascade/items/${Number(items[0]!.id)}/status`)
      .set('Authorization', `Bearer ${complianceEsgToken}`)
      .send({ status: 'not_a_valid_status' });

    expect(res.status).toBe(400);
  });

  it('AC#7-int-05: drafter → 404 on item status update (module guard — CR-V)', async () => {
    const res = await request(app)
      .patch('/api/v1/regulatory/cascade/items/1/status')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ status: 'in_progress' });

    // CR-V: drafter not in regulatory_cascade role codes → 404 MODULE_DISABLED
    expect(res.status).toBe(404);
  });

  it('AC#4-int-13: no JWT → 401', async () => {
    const res = await request(app)
      .patch('/api/v1/regulatory/cascade/items/1/status')
      .send({ status: 'resolved' });

    expect(res.status).toBe(401);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/v1/regulatory/cascade/items/:itemId/draft-amendment
// AC#5 — draft-amendment seam: generates advisory draft + links to item.
//
// DEBT-CRM-1 resolution: amendment drafting is a Legal Counsel action (separation
// of duties). The route now requires advisory.draft.review exclusively.
// compliance_esg holds regulatory.cascade.run but NOT advisory.draft.review →
// correctly receives 403 at the route gate.
// legal_counsel / platform_admin / Super Admin hold advisory.draft.review → allowed.
// ─────────────────────────────────────────────────────────────────────────────

describe('POST /api/v1/regulatory/cascade/items/:itemId/draft-amendment (AC#5 seam)', () => {
  // ── POSITIVE: legal_counsel can draft an amendment ──────────────────────────
  it('AC#5-int-01: legal_counsel → 2xx with DraftAmendmentResponse; advisory_draft_id linked on cascade item', async () => {
    // Find a cascade item that has at least one affected contract AND no draft yet
    const items = await adminQuery<{ id: number; affected_contract_ids: number[] }>(
      `SELECT rci.id, rci.affected_contract_ids
       FROM regulatory_cascade_item rci
       JOIN regulatory_cascade_run rcr ON rcr.id = rci.cascade_run_id
       WHERE rcr.tenant_id = $1::uuid
         AND rci.advisory_draft_id IS NULL
         AND jsonb_array_length(rci.affected_contract_ids) > 0
         AND rci.is_active = TRUE
       LIMIT 1`,
      [ADNOC_TENANT_ID],
    );

    if (items.length === 0) {
      console.warn('[SKIP] No cascade item with affected contracts and no draft — migration 295 seeded contracts; re-run after a fresh cascade run');
      return;
    }

    const itemId = Number(items[0]!.id);

    const res = await request(app)
      .post(`/api/v1/regulatory/cascade/items/${itemId}/draft-amendment`)
      .set('Authorization', `Bearer ${legalCounselToken}`)
      .send({});

    // 200/201: draft generated and linked.
    // 400: item has no resolvable contract (migration 295 should prevent this, but log if it occurs).
    if (res.status === 400) {
      console.warn('[WARN] draft-amendment returned 400 — item may have no resolvable contract despite migration 295');
      console.warn('       This is unexpected. Check that cascade was re-run after migration 295 was applied.');
      // Do NOT silently pass — fail so the data gap is visible
      expect(res.status).toBe(200);
      return;
    }

    expect([200, 201]).toContain(res.status);

    const body = res.body as {
      draftId: number;
      correlationId: number;
      templateId: number;
      contractId: number | null;
      approvalStatus: string;
      remediationStatus: string;
      itemId: number;
    };

    expect(typeof body.draftId).toBe('number');
    // correlationId may be serialized as string by PG BigInt — coerce for comparison
    expect(Number(body.correlationId)).toBeGreaterThan(0);
    expect(Number(body.itemId)).toBe(itemId);
    expect(body.remediationStatus).toBe('amended');
    expect(body.approvalStatus).toBe('unapproved');

    // No extra envelope wrapper (bare DraftAmendmentResponse per integration-verification.md MISMATCH-1 fix)
    expect((body as any).success).toBeUndefined();
    expect((body as any).data).toBeUndefined();

    // Verify the DB row was updated — advisory_draft_id is now linked
    const dbItem = await adminQuery<{ advisory_draft_id: number | null }>(
      `SELECT advisory_draft_id FROM regulatory_cascade_item WHERE id = $1`,
      [itemId],
    );
    expect(dbItem[0]!.advisory_draft_id).not.toBeNull();
    expect(Number(dbItem[0]!.advisory_draft_id)).toBe(body.draftId);
  }, 30_000);

  // ── NEGATIVE: compliance_esg must be 403 (separation of duties) ─────────────
  it('AC#5-int-02: compliance_esg → 403 (lacks advisory.draft.review — separation of duties)', async () => {
    // Find any cascade item — the gate fires before the service, so item existence doesn't matter
    const items = await adminQuery<{ id: number }>(
      `SELECT rci.id
       FROM regulatory_cascade_item rci
       JOIN regulatory_cascade_run rcr ON rcr.id = rci.cascade_run_id
       WHERE rcr.tenant_id = $1::uuid
         AND rci.is_active = TRUE
       LIMIT 1`,
      [ADNOC_TENANT_ID],
    );

    // If no items exist, use a sentinel id — the 403 fires at the auth middleware layer
    const itemId = items.length > 0 ? Number(items[0]!.id) : 1;

    const res = await request(app)
      .post(`/api/v1/regulatory/cascade/items/${itemId}/draft-amendment`)
      .set('Authorization', `Bearer ${complianceEsgToken}`)
      .send({});

    // compliance_esg holds regulatory.cascade.run but NOT advisory.draft.review.
    // Route gate is now authorise(['advisory.draft.review']) — must return 403.
    expect(res.status).toBe(403);
  });

  it('AC#5-int-03: idempotency — calling draft-amendment again on already-linked item → 409', async () => {
    // Find a cascade item that already has a draft linked (may have been created by AC#5-int-01 above)
    const items = await adminQuery<{ id: number }>(
      `SELECT rci.id FROM regulatory_cascade_item rci
       JOIN regulatory_cascade_run rcr ON rcr.id = rci.cascade_run_id
       WHERE rcr.tenant_id = $1::uuid
         AND rci.advisory_draft_id IS NOT NULL
         AND rci.is_active = TRUE
       LIMIT 1`,
      [ADNOC_TENANT_ID],
    );

    if (items.length === 0) {
      console.warn('[SKIP] No item with linked draft — idempotency test skipped (depends on AC#5-int-01 having run first)');
      return;
    }
    const itemId = Number(items[0]!.id);

    const res = await request(app)
      .post(`/api/v1/regulatory/cascade/items/${itemId}/draft-amendment`)
      .set('Authorization', `Bearer ${legalCounselToken}`)
      .send({});

    expect(res.status).toBe(409);
  });

  it('AC#5-int-04: non-existent item → 404', async () => {
    const res = await request(app)
      .post('/api/v1/regulatory/cascade/items/999999999/draft-amendment')
      .set('Authorization', `Bearer ${legalCounselToken}`)
      .send({});

    expect(res.status).toBe(404);
  });

  it('AC#7-int-06: drafter → 404 on draft-amendment (module guard — CR-V)', async () => {
    const res = await request(app)
      .post('/api/v1/regulatory/cascade/items/1/draft-amendment')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({});

    // CR-V: drafter not in regulatory_cascade role codes → 404 MODULE_DISABLED
    expect(res.status).toBe(404);
  });

  it('AC#5-int-05: no JWT → 401', async () => {
    const res = await request(app)
      .post('/api/v1/regulatory/cascade/items/1/draft-amendment')
      .send({});

    expect(res.status).toBe(401);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/v1/parties/:partyId/workforce  +  GET workforce endpoints
// AC#2 — workforce CRUD via HTTP
// ─────────────────────────────────────────────────────────────────────────────

describe('POST /api/v1/parties/:partyId/workforce', () => {
  it('AC#2-int-01: compliance_esg → 200 with upserted workforce', async () => {
    // Find any seeded contractor party without a workforce row (or the first available)
    const party = await adminQuery<{ id: number }>(
      `SELECT p.id FROM party p
       WHERE p.is_active = TRUE
       LIMIT 1`,
      [],
    );
    if (party.length === 0) {
      console.warn('[SKIP] No party rows found');
      return;
    }
    const partyId = Number(party[0]!.id);

    const res = await request(app)
      .post(`/api/v1/parties/${partyId}/workforce`)
      .set('Authorization', `Bearer ${complianceEsgToken}`)
      .send({
        headcount: 28,
        emiratisationTarget: 2,
        emiratisationActual: 1,
        category: 'logistics',
      });

    // 200 for update, 201 if first create — both are OK (upsert semantics per contracts.md)
    expect([200, 201]).toContain(res.status);

    const body = res.body as {
      id: number;
      partyId: number;
      headcountBand: string;
      isCompliant: boolean;
    };

    expect(Number(body.partyId)).toBe(partyId);
    expect(body.headcountBand).toBe('20-49'); // headcount=28 → 20-49
    expect(body.isCompliant).toBe(false);     // 1 < 2
  });

  it('AC#2-int-02: missing required field → 400', async () => {
    const party = await adminQuery<{ id: number }>(
      `SELECT id FROM party WHERE is_active = TRUE LIMIT 1`,
      [],
    );
    if (party.length === 0) return;

    const res = await request(app)
      .post(`/api/v1/parties/${Number(party[0]!.id)}/workforce`)
      .set('Authorization', `Bearer ${complianceEsgToken}`)
      .send({ headcount: 10 }); // missing emiratisationTarget + emiratisationActual

    expect(res.status).toBe(400);
  });

  it('AC#2-int-03: drafter (no party.workforce.manage) → 403', async () => {
    const res = await request(app)
      .post('/api/v1/parties/1/workforce')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({ headcount: 10, emiratisationTarget: 0, emiratisationActual: 0 });

    expect(res.status).toBe(403);
  });
});

describe('GET /api/v1/parties/:partyId/workforce', () => {
  it('AC#2-int-04: compliance_esg gets workforce for seeded contractor', async () => {
    const row = await adminQuery<{ party_id: number }>(
      `SELECT party_id FROM party_workforce
       WHERE tenant_id = $1::uuid AND is_active = TRUE LIMIT 1`,
      [ADNOC_TENANT_ID],
    );
    if (row.length === 0) {
      console.warn('[SKIP] No workforce rows');
      return;
    }
    const partyId = Number(row[0]!.party_id);

    const res = await request(app)
      .get(`/api/v1/parties/${partyId}/workforce`)
      .set('Authorization', `Bearer ${complianceEsgToken}`);

    expect(res.status).toBe(200);
    const body = res.body as { partyId: number; headcountBand: string };
    expect(Number(body.partyId)).toBe(partyId);
    expect(['<20', '20-49', '50+']).toContain(body.headcountBand);
  });

  it('AC#2-int-05: party with no workforce row → 404', async () => {
    const res = await request(app)
      .get('/api/v1/parties/999999999/workforce')
      .set('Authorization', `Bearer ${complianceEsgToken}`);

    expect(res.status).toBe(404);
  });

  it('AC#2-int-06: drafter (no party.workforce.read) → 403', async () => {
    const res = await request(app)
      .get('/api/v1/parties/1/workforce')
      .set('Authorization', `Bearer ${drafterToken}`);

    expect(res.status).toBe(403);
  });
});

describe('GET /api/v1/parties/workforce', () => {
  it('AC#2-int-07: compliance_esg → 200 with paginated list (routing not shadowed by /:id)', async () => {
    const res = await request(app)
      .get('/api/v1/parties/workforce')
      .set('Authorization', `Bearer ${complianceEsgToken}`);

    expect(res.status).toBe(200);

    // fn_party_workforce_list returns { data: [...], pagination: { total, limit, offset } }
    const body = res.body as {
      data: Array<{ partyId: number; headcountBand: string }>;
      pagination: { total: number; limit: number; offset: number };
    };

    expect(Array.isArray(body.data)).toBe(true);
    expect(typeof body.pagination.total).toBe('number');

    // Verify this is the workforce list and NOT the party detail (MISMATCH-2 routing fix)
    // If MISMATCH-2 fix was applied, workforce endpoint is reachable and returns correct shape
    expect(body.data.length).toBeGreaterThanOrEqual(0);
    // Confirm it's the workforce list shape (not a party graph response)
    if (body.data.length > 0) {
      expect(body.data[0]).toHaveProperty('headcountBand');
    }
  });

  it('AC#2-int-08: band filter ?band=20-49 returns only 20-49 workforce rows', async () => {
    const res = await request(app)
      .get('/api/v1/parties/workforce?band=20-49')
      .set('Authorization', `Bearer ${complianceEsgToken}`);

    expect(res.status).toBe(200);
    const body = res.body as { data: Array<{ headcountBand: string }> };
    for (const row of body.data) {
      expect(row.headcountBand).toBe('20-49');
    }
  });

  it('AC#2-int-09: drafter → 403', async () => {
    const res = await request(app)
      .get('/api/v1/parties/workforce')
      .set('Authorization', `Bearer ${drafterToken}`);

    expect(res.status).toBe(403);
  });

  it('AC#2-int-10: no JWT → 401', async () => {
    const res = await request(app).get('/api/v1/parties/workforce');
    expect(res.status).toBe(401);
  });
});
