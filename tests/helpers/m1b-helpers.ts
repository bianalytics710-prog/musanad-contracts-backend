/**
 * Shared helpers for M1b (Compose Wizard, Payment Schedules & Exports)
 * integration tests.
 *
 * Builds on m1a-helpers (admin login, contract creation, bypass-RLS pool,
 * cleanup-by-ids). Adds:
 *   - replacePaymentSchedule  — convenience wrapper for PUT /:id/payment-schedules
 *   - listPaymentSchedule     — convenience wrapper for GET /:id/payment-schedules
 *   - exportPdf               — convenience wrapper for GET /:id/export.pdf (binary)
 *   - exportXlsx              — convenience wrapper for GET /export.xlsx (binary)
 *   - cleanupPaymentSchedulesByContractIds  — hard-delete payment_schedule rows
 *   - cleanupAuditLogByEvent  — hard-delete audit_log rows from XLSX export tests
 *
 * NOTE: payment_schedule rows are FK-deleted by cleanupContractsByIds via the
 * contract delete cascade in M1a helpers (we extend that cleanup here for the
 * new child table — without this, M1a cleanup leaves orphaned payment_schedule
 * rows pointing at non-existent contracts).
 */
import request from 'supertest';
import type { Express } from 'express';
import { adminPool } from './m1a-helpers';

export interface PaymentScheduleRowInput {
  milestoneLabelEn: string;
  milestoneLabelAr?: string | null;
  milestoneNameEn?: string | null;
  milestoneNameAr?: string | null;
  amountAed: number;
  dueDate?: string | null;
  paidAt?: string | null;
  status?: 'pending' | 'due' | 'paid' | 'overdue' | 'waived' | 'cancelled';
  recurrence?: 'once' | 'monthly' | 'quarterly' | 'annually' | null;
  invoiceRef?: string | null;
}

/** PUT /api/v1/contracts/:id/payment-schedules — wrapper. */
export const replacePaymentSchedule = async (
  app: Express,
  token: string,
  contractId: number,
  rows: PaymentScheduleRowInput[],
): Promise<request.Response> =>
  await request(app)
    .put(`/api/v1/contracts/${contractId}/payment-schedules`)
    .set('Authorization', `Bearer ${token}`)
    .send({ rows });

/** GET /api/v1/contracts/:id/payment-schedules — wrapper. */
export const listPaymentSchedule = async (
  app: Express,
  token: string,
  contractId: number,
  status?: string,
): Promise<request.Response> => {
  let req = request(app)
    .get(`/api/v1/contracts/${contractId}/payment-schedules`)
    .set('Authorization', `Bearer ${token}`);
  if (status) {
    req = req.query({ status });
  }
  return await req;
};

/** GET /api/v1/contracts/:id/export.pdf — wrapper. Returns supertest response. */
export const exportPdf = async (
  app: Express,
  token: string,
  contractId: number,
  language?: 'en' | 'ar' | 'bilingual',
): Promise<request.Response> => {
  let req = request(app)
    .get(`/api/v1/contracts/${contractId}/export.pdf`)
    .set('Authorization', `Bearer ${token}`)
    .buffer(true)
    .parse((res, callback) => {
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => callback(null, Buffer.concat(chunks)));
    });
  if (language) {
    req = req.query({ language });
  }
  return await req;
};

/** GET /api/v1/contracts/export.xlsx — wrapper. Returns supertest response. */
export const exportXlsx = async (
  app: Express,
  token: string,
  query: Record<string, string | number | string[]> = {},
): Promise<request.Response> =>
  await request(app)
    .get('/api/v1/contracts/export.xlsx')
    .set('Authorization', `Bearer ${token}`)
    .query(query)
    .buffer(true)
    .parse((res, callback) => {
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => callback(null, Buffer.concat(chunks)));
    });

/**
 * Cleanup helper — hard-delete payment_schedule rows for the given contract
 * ids. Called BEFORE cleanupContractsByIds so the FK is satisfied.
 */
export const cleanupPaymentSchedulesByContractIds = async (ids: number[]): Promise<void> => {
  if (ids.length === 0) return;
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      'DELETE FROM payment_schedule WHERE contract_id = ANY($1::BIGINT[])',
      [ids],
    );
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Cleanup helper — hard-delete audit_log rows emitted by XLSX export tests
 * (action='INSERT', new_values.event='EXPORT'). Filtered by changed_by to
 * limit blast radius to rows the current test admin emitted.
 *
 * Note: audit_log uses `changed_by` (M0 schema), not `actor_id`. The fn_
 * helper signature is `fn_audit_log_record(... p_actor_id BIGINT)` and
 * INSERTs into audit_log.changed_by.
 */
export const cleanupAuditLogByEvent = async (
  actorId: number,
  event: string = 'EXPORT',
): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      `DELETE FROM audit_log
         WHERE changed_by = $1
           AND action = 'INSERT'
           AND new_values->>'event' = $2`,
      [actorId, event],
    );
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/** Build a minimal valid PaymentScheduleCreateDto row for tests. */
export const buildPaymentRow = (
  overrides: Partial<PaymentScheduleRowInput> = {},
): PaymentScheduleRowInput => ({
  milestoneLabelEn: overrides.milestoneLabelEn ?? `Milestone ${Math.random().toString(36).slice(2, 6)}`,
  amountAed: overrides.amountAed ?? 1000,
  ...overrides,
});
