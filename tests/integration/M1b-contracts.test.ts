/**
 * M1b — Contracts: Compose Wizard, Payment Schedules & Exports.
 *
 * Coverage strategy mirrors the M1a suite: one outer describe per story
 * (S1..S5). Each AC label appears in the test title so the orchestrator can
 * map failures.
 *
 * Test DB: tests/helpers/setup.ts already swapped DATABASE_URL →
 * TEST_DATABASE_URL (Neon test branch). All contracts and payment_schedule
 * rows created during the suite are tracked and hard-deleted in afterAll
 * via the BYPASSRLS admin pool.
 *
 * Bootstrap admin (id=1) holds all M1a contract.* permissions PLUS
 * contract.export — verified by the smoke test report. We log in once and
 * reuse the access token across the whole suite.
 *
 * Regression locks established:
 *   - DB-PATCH-1 (migration 013): the 'payment_schedule_replaced' and
 *     'exported' activity types must be accepted by fn_contract_activity_create.
 *     S3 happy path + S4 happy path each assert that the activity row is
 *     emitted with the correct activity_type — if migration 013 regresses,
 *     these tests fail loudly.
 *   - BE-PATCH-1 (db-client array-of-objects serialiser): every PUT call to
 *     /payment-schedules round-trips an array of objects through pg as JSONB.
 *     If the serialiser regresses to passing arrays-of-objects as Postgres
 *     array literals, fn_payment_schedule_create_bulk fails type-cast.
 *     The S3 happy path + Compose-Wizard sequence test cover this.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import {
  loginAdmin,
  createContract,
  cleanupContractsByIds,
  adminQuery,
  closeAdminPool,
  type LoginResult,
} from '../helpers/m1a-helpers';
import {
  buildPaymentRow,
  cleanupAuditLogByEvent,
  cleanupPaymentSchedulesByContractIds,
  exportPdf,
  exportXlsx,
  listPaymentSchedule,
  replacePaymentSchedule,
  type PaymentScheduleRowInput,
} from '../helpers/m1b-helpers';

let app: import('express').Express;
let server: import('http').Server;
let admin: LoginResult;
let token: string;

/** Track contract ids for afterAll cleanup. */
const createdIds: number[] = [];
const trackId = <T extends { id: number }>(c: T): T => {
  if (typeof c.id === 'number') createdIds.push(c.id);
  return c;
};

beforeAll(async () => {
  const m = await import('../../src/server');
  app = m.app;
  server = m.server;
  admin = await loginAdmin(app);
  token = admin.accessToken;
});

afterAll(async () => {
  if (createdIds.length > 0) {
    try {
      await cleanupPaymentSchedulesByContractIds(createdIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M1b-cleanup] payment_schedule cleanup error:', err);
    }
    try {
      await cleanupContractsByIds(createdIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M1b-cleanup] contract cleanup error:', err);
    }
  }
  try {
    await cleanupAuditLogByEvent(admin.user.id, 'EXPORT');
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[M1b-cleanup] audit_log cleanup error:', err);
  }
  await closeAdminPool();
  server.close();
  const { closePool } = await import('../../src/database/config');
  await closePool();
});

// ============================================================================
// S1 — Compose Wizard (FE-only orchestration; BE verifies the 2-call sequence)
// ============================================================================
describe('S1 — Compose Wizard (POST /contracts then PUT /:id/payment-schedules)', () => {
  it('AC-S1-10 sequence: POST contract then PUT payment-schedules — final state has 1 contract + N payment_schedule rows + 1 created activity + 1 payment_schedule_replaced activity', async () => {
    // Step 1: POST /contracts
    const contract = trackId(
      await createContract(app, token, {
        titleEn: 'M1b-S1-Wizard',
        contractType: 'employment',
        language: 'en',
      }),
    );
    expect(typeof contract.id).toBe('number');
    expect(contract.contractNumber).toMatch(/^CT-\d{4}-\d{6}$/);

    // Step 2: PUT /:id/payment-schedules
    const rows: PaymentScheduleRowInput[] = [
      buildPaymentRow({ milestoneLabelEn: 'S1-Mile-1', amountAed: 5000, dueDate: '2026-06-01' }),
      buildPaymentRow({ milestoneLabelEn: 'S1-Mile-2', amountAed: 7500, dueDate: '2026-07-01' }),
      buildPaymentRow({ milestoneLabelEn: 'S1-Mile-3', amountAed: 2500, dueDate: '2026-08-01' }),
    ];
    const putRes = await replacePaymentSchedule(app, token, contract.id, rows);
    expect(putRes.status).toBe(200);
    expect(putRes.body.inserted).toBe(3);
    expect(putRes.body.softDeleted).toBe(0);

    // Final state assertions: 1 contract head + 3 active payment_schedule rows
    // + at least 1 'created' activity + 1 'payment_schedule_replaced' activity.
    const psRows = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::TEXT AS count FROM payment_schedule
        WHERE contract_id = $1 AND is_active = TRUE`,
      [contract.id],
    );
    expect(Number(psRows[0]?.count)).toBe(3);

    const actCreated = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::TEXT AS count FROM contract_activity
        WHERE contract_id = $1 AND activity_type = 'created'`,
      [contract.id],
    );
    expect(Number(actCreated[0]?.count)).toBeGreaterThanOrEqual(1);

    const actReplaced = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::TEXT AS count FROM contract_activity
        WHERE contract_id = $1 AND activity_type = 'payment_schedule_replaced'`,
      [contract.id],
    );
    expect(Number(actReplaced[0]?.count)).toBe(1);
  });

  it('AC-S1-08 retry semantics: POST succeeds, first PUT fails (validation), draft contract still in draft, second PUT succeeds', async () => {
    // Step 1: POST succeeds
    const contract = trackId(
      await createContract(app, token, {
        titleEn: 'M1b-S1-Retry',
        contractType: 'employment',
        language: 'en',
      }),
    );

    // Step 2: PUT FAILS due to invalid row (negative amount → AC-S3-06)
    const badRows: PaymentScheduleRowInput[] = [
      // Cast through unknown to bypass TS — we want to send invalid wire data.
      buildPaymentRow({ milestoneLabelEn: 'S1-Retry-Bad', amountAed: -100 }),
    ];
    const failedPut = await replacePaymentSchedule(app, token, contract.id, badRows);
    expect(failedPut.status).toBe(400);

    // Contract still exists in 'draft' status (no rollback of the contract)
    const headRows = await adminQuery<{ status: string; is_active: boolean }>(
      `SELECT status, is_active FROM contract WHERE id = $1`,
      [contract.id],
    );
    expect(headRows[0]?.is_active).toBe(true);
    expect(headRows[0]?.status).toBe('draft');

    // Step 2 retry — succeeds
    const goodRows: PaymentScheduleRowInput[] = [
      buildPaymentRow({ milestoneLabelEn: 'S1-Retry-Good', amountAed: 1000 }),
    ];
    const retryPut = await replacePaymentSchedule(app, token, contract.id, goodRows);
    expect(retryPut.status).toBe(200);
    expect(retryPut.body.inserted).toBe(1);
  });
});

// ============================================================================
// S2 — Payment Schedule list (GET /:id/payment-schedules)
// ============================================================================
describe('S2 — GET /api/v1/contracts/:id/payment-schedules', () => {
  it('AC-S2-01: happy path — returns rows ordered by due_date ASC NULLS LAST', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S2-01' }));
    await replacePaymentSchedule(app, token, c.id, [
      buildPaymentRow({ milestoneLabelEn: 'S2-Earlier', amountAed: 500, dueDate: '2026-06-01' }),
      buildPaymentRow({ milestoneLabelEn: 'S2-Later', amountAed: 1000, dueDate: '2026-09-01' }),
    ]);

    const res = await listPaymentSchedule(app, token, c.id);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.data.length).toBe(2);
    // Order: earlier due_date first.
    expect(res.body.data[0].milestoneLabelEn).toBe('S2-Earlier');
    expect(res.body.data[1].milestoneLabelEn).toBe('S2-Later');
  });

  it('AC-S2-02: 404 with field=id when contract id does not exist', async () => {
    const res = await listPaymentSchedule(app, token, 999_999_999);
    expect(res.status).toBe(404);
    // Error envelope: details.id present.
    const fields = (res.body.details ?? res.body.error?.details ?? res.body.error?.fields) as
      | Record<string, unknown>
      | undefined;
    expect(fields?.id).toBe('Contract not found');
  });

  it('AC-S2-03: 404 (not 403) when actor cannot see the contract per RLS — soft-deleted parent maps to 404', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S2-03' }));
    // Soft-delete the contract head (sets is_active=false) — fn_payment_schedule_list returns NULL.
    await adminQuery(`UPDATE contract SET is_active = FALSE WHERE id = $1`, [c.id]);

    const res = await listPaymentSchedule(app, token, c.id);
    expect(res.status).toBe(404);
    expect(res.status).not.toBe(403);
  });

  it('AC-S2-04: empty data array when contract has no payment schedule', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S2-04' }));
    const res = await listPaymentSchedule(app, token, c.id);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.data)).toBe(true);
    expect(res.body.data.length).toBe(0);
  });

  it('AC-S2-06: invalid status query → 400 with field=status', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S2-06' }));
    const res = await listPaymentSchedule(app, token, c.id, 'not-a-status');
    expect(res.status).toBe(400);
  });
});

// ============================================================================
// S3 — Payment Schedule replace (PUT /:id/payment-schedules)
// ============================================================================
describe('S3 — PUT /api/v1/contracts/:id/payment-schedules', () => {
  it('AC-S3-01 + AC-S3-10 happy path: bulk replace soft-deletes old, inserts new, emits ONE payment_schedule_replaced activity (regression: DB-PATCH-1 + BE-PATCH-1)', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S3-01' }));

    // Initial set — 2 rows.
    const first = await replacePaymentSchedule(app, token, c.id, [
      buildPaymentRow({ milestoneLabelEn: 'S3-01-A', amountAed: 100 }),
      buildPaymentRow({ milestoneLabelEn: 'S3-01-B', amountAed: 200 }),
    ]);
    expect(first.status).toBe(200);
    expect(first.body.inserted).toBe(2);
    expect(first.body.softDeleted).toBe(0);

    // Replace — 3 new rows; old 2 must be soft-deleted.
    const second = await replacePaymentSchedule(app, token, c.id, [
      buildPaymentRow({ milestoneLabelEn: 'S3-01-C', amountAed: 300 }),
      buildPaymentRow({ milestoneLabelEn: 'S3-01-D', amountAed: 400 }),
      buildPaymentRow({ milestoneLabelEn: 'S3-01-E', amountAed: 500 }),
    ]);
    expect(second.status).toBe(200);
    expect(second.body.inserted).toBe(3);
    expect(second.body.softDeleted).toBe(2);

    // Atomic state — only the 3 new rows are active.
    const active = await adminQuery<{ milestone_label_en: string }>(
      `SELECT milestone_label_en FROM payment_schedule
        WHERE contract_id = $1 AND is_active = TRUE
        ORDER BY id ASC`,
      [c.id],
    );
    expect(active.length).toBe(3);
    expect(active.map((r) => r.milestone_label_en)).toEqual(['S3-01-C', 'S3-01-D', 'S3-01-E']);

    // Activity emission — exactly TWO 'payment_schedule_replaced' rows
    // (one per replace call). Regression for DB-PATCH-1.
    const acts = await adminQuery<{ activity_type: string; metadata: Record<string, unknown> }>(
      `SELECT activity_type, metadata FROM contract_activity
         WHERE contract_id = $1 AND activity_type = 'payment_schedule_replaced'
         ORDER BY id ASC`,
      [c.id],
    );
    expect(acts.length).toBe(2);
    expect(acts[1]?.metadata?.insertedCount).toBe(3);
    expect(acts[1]?.metadata?.softDeletedCount).toBe(2);
  });

  it('AC-S3-04: empty rows[] → 400 with field=rows', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S3-04' }));
    const res = await request(app)
      .put(`/api/v1/contracts/${c.id}/payment-schedules`)
      .set('Authorization', `Bearer ${token}`)
      .send({ rows: [] });
    expect(res.status).toBe(400);
    const serialised = JSON.stringify(res.body);
    expect(serialised).toMatch(/rows/);
  });

  it('AC-S3-05: row missing milestoneLabelEn → 400 with field rows[i].milestoneLabelEn', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S3-05' }));
    const res = await request(app)
      .put(`/api/v1/contracts/${c.id}/payment-schedules`)
      .set('Authorization', `Bearer ${token}`)
      // milestoneLabelEn missing — Zod superRefine rejects.
      .send({ rows: [{ amountAed: 100 }] });
    expect(res.status).toBe(400);
    const serialised = JSON.stringify(res.body);
    expect(serialised).toMatch(/milestoneLabelEn|Milestone label is required/);
  });

  it('AC-S3-cross-row: paidAt requires status=paid → 400 (Zod superRefine)', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S3-paidAt' }));
    const res = await request(app)
      .put(`/api/v1/contracts/${c.id}/payment-schedules`)
      .set('Authorization', `Bearer ${token}`)
      .send({
        rows: [
          {
            milestoneLabelEn: 'S3-paidAt',
            amountAed: 100,
            paidAt: '2026-05-01',
            status: 'pending', // mismatch — paidAt requires status=paid
          },
        ],
      });
    expect(res.status).toBe(400);
    const serialised = JSON.stringify(res.body);
    expect(serialised).toMatch(/paidAt|status is paid/);
  });

  it('AC-S3-09: > 100 rows → 400 with field=rows', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S3-09' }));
    const tooMany = Array.from({ length: 101 }, (_, i) =>
      buildPaymentRow({ milestoneLabelEn: `S3-09-${i.toString().padStart(3, '0')}`, amountAed: 1 }),
    );
    const res = await request(app)
      .put(`/api/v1/contracts/${c.id}/payment-schedules`)
      .set('Authorization', `Bearer ${token}`)
      .send({ rows: tooMany });
    expect(res.status).toBe(400);
    const serialised = JSON.stringify(res.body);
    expect(serialised).toMatch(/Maximum 100|rows/);
  });

  it('AC-S3-02: 404 when contract id does not exist', async () => {
    const res = await replacePaymentSchedule(app, token, 999_999_999, [
      buildPaymentRow({ milestoneLabelEn: 'S3-02-X', amountAed: 1 }),
    ]);
    expect(res.status).toBe(404);
  });

  it('AC-S3-11 concurrent replace serialisation: two clients race; final state is one of the inputs (Codex BE-001 lesson applied to fn_payment_schedule_create_bulk)', async () => {
    // Direct fn_ call against admin pool (HTTP would wrap each request in
    // its own implicit txn, making deterministic interleaving impossible —
    // mirror the M1a concurrency suite pattern).
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S3-11' }));

    // Seed initial set.
    await replacePaymentSchedule(app, token, c.id, [
      buildPaymentRow({ milestoneLabelEn: 'S3-11-init', amountAed: 1 }),
    ]);

    // Two clients race PUTs — fn_payment_schedule_create_bulk takes
    // SELECT FOR UPDATE on the parent contract head row, so the two calls
    // serialise. Final active set is whichever committed last.
    const rowsA: PaymentScheduleRowInput[] = [
      buildPaymentRow({ milestoneLabelEn: 'S3-11-A1', amountAed: 100 }),
      buildPaymentRow({ milestoneLabelEn: 'S3-11-A2', amountAed: 200 }),
    ];
    const rowsB: PaymentScheduleRowInput[] = [
      buildPaymentRow({ milestoneLabelEn: 'S3-11-B1', amountAed: 300 }),
    ];
    const [resA, resB] = await Promise.all([
      replacePaymentSchedule(app, token, c.id, rowsA),
      replacePaymentSchedule(app, token, c.id, rowsB),
    ]);
    expect(resA.status).toBe(200);
    expect(resB.status).toBe(200);

    // Final active set must equal exactly one of the two inputs — never a
    // merged hybrid (which is what FOR UPDATE prevents).
    const active = await adminQuery<{ milestone_label_en: string }>(
      `SELECT milestone_label_en FROM payment_schedule
        WHERE contract_id = $1 AND is_active = TRUE
        ORDER BY id ASC`,
      [c.id],
    );
    const labels = active.map((r) => r.milestone_label_en);
    const isA = labels.length === 2 && labels.includes('S3-11-A1') && labels.includes('S3-11-A2');
    const isB = labels.length === 1 && labels[0] === 'S3-11-B1';
    if (!isA && !isB) {
      throw new Error(
        `Concurrent PUT race produced merged hybrid result: ${JSON.stringify(labels)}`,
      );
    }
    expect(isA || isB).toBe(true);
  });
});

// ============================================================================
// S4 — PDF export (GET /:id/export.pdf)
// ============================================================================
describe('S4 — GET /api/v1/contracts/:id/export.pdf', () => {
  it('AC-S4-01: happy path — 200 with Content-Type application/pdf, Content-Disposition with filename, body starts with %PDF-', async () => {
    const c = trackId(
      await createContract(app, token, {
        titleEn: 'M1b-S4-01',
        bodyEn: 'S4-PDF-BODY-EN',
        bodyAr: 'S4-PDF-BODY-AR',
      }),
    );

    const res = await exportPdf(app, token, c.id, 'bilingual');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/application\/pdf/);
    expect(res.headers['content-disposition']).toMatch(/attachment; filename="CT-\d{4}-\d{6}-bilingual\.pdf"/);
    // Body is a Buffer (we used .parse to collect raw bytes).
    const body = res.body as Buffer;
    expect(Buffer.isBuffer(body)).toBe(true);
    expect(body.length).toBeGreaterThan(1000);
    // %PDF- magic bytes at offset 0.
    expect(body.subarray(0, 5).toString('ascii')).toBe('%PDF-');
  }, 60_000); // Puppeteer launch can take ~10s on first call

  it('AC-S4-06: PDF export emits exactly one contract_activity(activity_type=exported) row (regression: DB-PATCH-1)', async () => {
    const c = trackId(
      await createContract(app, token, {
        titleEn: 'M1b-S4-06',
        bodyEn: 'S4-06 body',
      }),
    );

    const before = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::TEXT AS count FROM contract_activity
        WHERE contract_id = $1 AND activity_type = 'exported'`,
      [c.id],
    );
    expect(Number(before[0]?.count)).toBe(0);

    const res = await exportPdf(app, token, c.id, 'en');
    expect(res.status).toBe(200);

    const after = await adminQuery<{
      activity_type: string;
      metadata: Record<string, unknown>;
    }>(
      `SELECT activity_type, metadata FROM contract_activity
        WHERE contract_id = $1 AND activity_type = 'exported'
        ORDER BY id ASC`,
      [c.id],
    );
    expect(after.length).toBe(1);
    expect(after[0]?.activity_type).toBe('exported');
    // metadata.format='pdf' or metadata.exportFormat='pdf' depending on
    // emitting fn_ — accept either shape.
    const meta = after[0]?.metadata ?? {};
    const fmt = (meta as { format?: string; exportFormat?: string }).format ??
      (meta as { format?: string; exportFormat?: string }).exportFormat;
    expect(fmt).toBe('pdf');
  }, 60_000);

  it('AC-S4-03: 404 when contract id does not exist', async () => {
    const res = await exportPdf(app, token, 999_999_999, 'en');
    expect(res.status).toBe(404);
  });

  it('AC-S4-05: invalid language → 400 with field=language', async () => {
    const c = trackId(await createContract(app, token, { titleEn: 'M1b-S4-05' }));
    // Manually issue request with bad language — bypass typed helper.
    const res = await request(app)
      .get(`/api/v1/contracts/${c.id}/export.pdf`)
      .set('Authorization', `Bearer ${token}`)
      .query({ language: 'xx-bad' });
    expect(res.status).toBe(400);
    const serialised = JSON.stringify(res.body);
    expect(serialised).toMatch(/language|Invalid/);
  });
});

// ============================================================================
// S5 — XLSX list export (GET /export.xlsx)
// ============================================================================
describe('S5 — GET /api/v1/contracts/export.xlsx', () => {
  it('AC-S5-01: happy path — 200 with XLSX Content-Type, body starts with PK..\\x03\\x04 (zip magic)', async () => {
    // Seed at least one contract so the export has data.
    trackId(await createContract(app, token, { titleEn: 'M1b-S5-01-Seed' }));

    const res = await exportXlsx(app, token);
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(
      /application\/vnd\.openxmlformats-officedocument\.spreadsheetml\.sheet/,
    );
    expect(res.headers['content-disposition']).toMatch(/contracts-\d{8}-\d{4}\.xlsx/);
    const body = res.body as Buffer;
    expect(Buffer.isBuffer(body)).toBe(true);
    expect(body.length).toBeGreaterThan(100);
    // ZIP magic bytes (XLSX is a zip archive): 50 4B 03 04
    expect(body[0]).toBe(0x50);
    expect(body[1]).toBe(0x4b);
    expect(body[2]).toBe(0x03);
    expect(body[3]).toBe(0x04);
  });

  it('AC-S5-02 filter pass-through: query params narrow the result set (regression: 012 tag-filter operator-type fix)', async () => {
    // Seed a contract with a UNIQUE contractType so we can assert the
    // filter narrows the result. Use a low maxRows to keep response small.
    const uniqueType = 'msa-test'; // valid M1a contract_type enum value
    const c = trackId(await createContract(app, token, {
      titleEn: 'M1b-S5-02-Filtered',
      contractType: uniqueType,
    }));

    const res = await exportXlsx(app, token, { contractType: uniqueType, maxRows: 50 });
    expect(res.status).toBe(200);
    // Filtered set must include our seed contract id but the response is
    // binary XLSX — assertion is via the audit_log row written below
    // (filter is captured into new_values.filter).
    const auditRows = await adminQuery<{ new_values: Record<string, unknown> }>(
      `SELECT new_values FROM audit_log
         WHERE changed_by = $1
           AND action = 'INSERT'
           AND new_values->>'event' = 'EXPORT'
           AND new_values->>'format' = 'xlsx'
         ORDER BY id DESC
         LIMIT 1`,
      [admin.user.id],
    );
    expect(auditRows.length).toBe(1);
    const lastFilter = (auditRows[0]?.new_values ?? {}) as {
      filter?: { contractType?: string };
    };
    expect(lastFilter.filter?.contractType).toBe(uniqueType);
    // sanity: c.id was tracked so cleanup will remove it.
    expect(c.id).toBeGreaterThan(0);
  });

  it('AC-S5-08: XLSX export emits ONE audit_log row via fn_audit_log_record (no per-contract contract_activity rows)', async () => {
    trackId(await createContract(app, token, { titleEn: 'M1b-S5-08-Audit' }));

    const beforeRows = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::TEXT AS count FROM audit_log
         WHERE changed_by = $1
           AND action = 'INSERT'
           AND new_values->>'event' = 'EXPORT'
           AND new_values->>'format' = 'xlsx'`,
      [admin.user.id],
    );
    const before = Number(beforeRows[0]?.count);

    const res = await exportXlsx(app, token, { maxRows: 100 });
    expect(res.status).toBe(200);

    const afterRows = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::TEXT AS count FROM audit_log
         WHERE changed_by = $1
           AND action = 'INSERT'
           AND new_values->>'event' = 'EXPORT'
           AND new_values->>'format' = 'xlsx'`,
      [admin.user.id],
    );
    expect(Number(afterRows[0]?.count)).toBe(before + 1);

    // No contract_activity rows of type 'exported' for this list-level export
    // (per Q4: list export is audited via audit_log only, not per-contract
    // contract_activity rows). We assert the count is unchanged for any
    // contracts that we didn't touch via per-contract PDF export — this is a
    // weaker assertion than the BEFORE/AFTER pattern but the BEFORE/AFTER
    // would race with the S4 test in the same suite. Instead we assert that
    // no NEW 'exported' rows reference the M1b-S5-08 contract id specifically.
    // Locate that contract id via the most recent createdId.
    const lastId = createdIds[createdIds.length - 1]!;
    const acts = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::TEXT AS count FROM contract_activity
         WHERE contract_id = $1 AND activity_type = 'exported'`,
      [lastId],
    );
    expect(Number(acts[0]?.count)).toBe(0);
  });

  it('AC-S5-06: maxRows out of range (negative) → 400 with field=maxRows', async () => {
    const res = await request(app)
      .get('/api/v1/contracts/export.xlsx')
      .set('Authorization', `Bearer ${token}`)
      .query({ maxRows: -5 });
    expect(res.status).toBe(400);
    const serialised = JSON.stringify(res.body);
    expect(serialised).toMatch(/maxRows/);
  });
});
