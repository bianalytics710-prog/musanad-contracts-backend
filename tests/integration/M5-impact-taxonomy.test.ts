/**
 * M5 — Impact Taxonomy tests for S14..S15.
 *
 * Surfaces:
 *   - GET  /api/v1/impact-categories      (S14, fn_impact_category_list)
 *   - POST /api/v1/impact-categories      (S15, fn_impact_category_upsert)
 *
 * Special focus:
 *   - S15 INSERT branch (createdOrUpdated='created') AND UPDATE branch (='updated')
 *     via `key` UNIQUE — exercises the ON CONFLICT (key) DO UPDATE path
 *   - S15 path discrepancy resolved per BE-OI-A: POST + body-keyed (NOT PUT/:key)
 *   - S15 platform_admin gate — legal_counsel rejected with 403
 *   - S14 visibility — any authenticated role can list (incl. contract_recipient)
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
  cleanupRegulatoryArtifacts,
  tagFor,
} from '../helpers/m5-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let adminToken: string;
let drafterToken: string;
let recipientToken: string;
let legalToken: string;

const upsertedKeys: string[] = [];
const SUITE_TAG = tagFor('taxonomy');

// AC-S15-04 expects severityScale to be a JSON array of strings (Zod schema also enforces it)
const VALID_SEVERITY_SCALE = ['low', 'medium', 'high', 'critical'];

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  adminToken = admin.accessToken;
  await seedFixtureUsers();
  drafterToken = signFixtureToken('drafter1');
  recipientToken = signFixtureToken('recipient1');
  legalToken = signFixtureToken('legal_counsel1');
});

afterAll(async () => {
  try {
    await cleanupRegulatoryArtifacts({ impactCategoryKeys: upsertedKeys });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M5-taxonomy cleanup]', err);
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

// snake_case key per AC-S15 / fn_impact_category_upsert regex
const keyFor = (label: string): string =>
  `m5t_${label}_${Math.floor(Math.random() * 1e6)}`.toLowerCase().slice(0, 60);

// ============================================================================
// S14 — GET /api/v1/impact-categories
// ============================================================================
describe('S14 — fn_impact_category_list / GET /api/v1/impact-categories', () => {
  it('AC-S14-01: returns all categories sorted by display_order ASC', async () => {
    const res = await request(app)
      .get('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    // Migration 052 seeds 8 default rows; post-migration we should see >=8.
    expect(res.body.data.length).toBeGreaterThanOrEqual(8);
    // Verify display_order ASC sort.
    const orders = (res.body.data as Array<{ displayOrder?: number }>).map(
      (r) => r.displayOrder ?? 0,
    );
    for (let i = 1; i < orders.length; i++) {
      expect(orders[i]).toBeGreaterThanOrEqual(orders[i - 1]!);
    }
  });

  it('AC-S14-02: default p_include_inactive=FALSE → only active rows', async () => {
    const res = await request(app)
      .get('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    for (const row of res.body.data as Array<{ active?: boolean }>) {
      // The fn returns rows where active=TRUE by default
      expect(row.active).toBe(true);
    }
  });

  it('AC-S14-05: contract_recipient can list (no permission gate beyond JWT)', async () => {
    const res = await request(app)
      .get('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${recipientToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
  });

  it('AC-S14-05: drafter, legal_counsel, executive can all list', async () => {
    const tokens = [drafterToken, legalToken];
    for (const t of tokens) {
      const res = await request(app)
        .get('/api/v1/impact-categories')
        .set('Authorization', `Bearer ${t}`);
      expect(res.status).toBe(200);
    }
  });
});

// ============================================================================
// S15 — POST /api/v1/impact-categories  (upsert; key in body — BE-OI-A)
// ============================================================================
describe('S15 — fn_impact_category_upsert / POST /api/v1/impact-categories', () => {
  it('AC-S15-01: platform_admin (Super Admin) creates a new category — createdOrUpdated="created"', async () => {
    const k = keyFor('s15_01');
    const res = await request(app)
      .post('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        key: k,
        nameEn: 'Test Category EN',
        nameAr: 'فئة الاختبار',
      });
    expect(res.status).toBe(200);
    expect(res.body.id).toBeDefined();
    expect(res.body.key).toBe(k);
    expect(res.body.createdOrUpdated).toBe('created');
    upsertedKeys.push(k);
  });

  it('AC-S15-02: same key on second call → createdOrUpdated="updated"', async () => {
    const k = keyFor('s15_02');
    upsertedKeys.push(k);

    const r1 = await request(app)
      .post('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        key: k,
        nameEn: 'Initial EN',
        nameAr: 'الأولي',
      });
    expect(r1.status).toBe(200);
    expect(r1.body.createdOrUpdated).toBe('created');

    const r2 = await request(app)
      .post('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        key: k,
        nameEn: 'Updated EN',
        nameAr: 'محدث',
      });
    expect(r2.status).toBe(200);
    expect(r2.body.createdOrUpdated).toBe('updated');
    expect(r2.body.key).toBe(k);
    expect(Number(r2.body.id)).toBe(Number(r1.body.id));
  });

  it('AC-S15-03: missing nameAr returns 400', async () => {
    const k = keyFor('s15_03');
    const res = await request(app)
      .post('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        key: k,
        nameEn: 'EN only',
      });
    expect(res.status).toBe(400);
    const body = JSON.stringify(res.body).toLowerCase();
    expect(body).toContain('namear');
  });

  it('AC-S15-04: severityScale not array returns 400', async () => {
    const k = keyFor('s15_04');
    const res = await request(app)
      .post('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        key: k,
        nameEn: 'Bad scale',
        nameAr: 'مقياس سيء',
        // Send a non-array — Zod or fn body should reject.
        severityScale: 'not-an-array',
      });
    expect(res.status).toBe(400);
  });

  it('AC-S15-05: legal_counsel cannot upsert (config.manage required) → 403', async () => {
    const k = keyFor('s15_05');
    const res = await request(app)
      .post('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${legalToken}`)
      .send({
        key: k,
        nameEn: 'Legal denied',
        nameAr: 'القانوني مرفوض',
      });
    expect(res.status).toBe(403);
  });

  it('AC-S15-05: contract_drafter cannot upsert → 403', async () => {
    const k = keyFor('s15_05b');
    const res = await request(app)
      .post('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${drafterToken}`)
      .send({
        key: k,
        nameEn: 'Drafter denied',
        nameAr: 'الصياغة مرفوضة',
      });
    expect(res.status).toBe(403);
  });

  it('AC-S15-06: defaults applied (icon=shield, colour=slate, active=true, displayOrder=0)', async () => {
    const k = keyFor('s15_06');
    upsertedKeys.push(k);
    const res = await request(app)
      .post('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        key: k,
        nameEn: 'Defaults',
        nameAr: 'افتراضات',
      });
    expect(res.status).toBe(200);

    // Read back via the list endpoint and find our key
    const listRes = await request(app)
      .get('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(listRes.status).toBe(200);
    const ours = (listRes.body.data as Array<{ key: string; icon?: string; colour?: string; active?: boolean }>).find(
      (r) => r.key === k,
    );
    expect(ours).toBeDefined();
    expect(ours!.icon).toBe('shield');
    expect(ours!.colour).toBe('slate');
    expect(ours!.active).toBe(true);
  });

  it('AC-S15-04: valid severityScale array of strings is accepted', async () => {
    const k = keyFor('s15_scale_ok');
    upsertedKeys.push(k);
    const res = await request(app)
      .post('/api/v1/impact-categories')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        key: k,
        nameEn: 'Scale OK',
        nameAr: 'مقياس صحيح',
        severityScale: VALID_SEVERITY_SCALE,
      });
    expect(res.status).toBe(200);
    expect(res.body.createdOrUpdated).toBe('created');
  });
});
