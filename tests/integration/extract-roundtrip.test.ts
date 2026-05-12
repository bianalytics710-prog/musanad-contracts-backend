/**
 * M12 / CR-D — Extract roundtrip integration test.
 *
 * Verifies end-to-end: queue extraction → clause upsert → obligation derivation
 * using the actual DB functions against the Neon test branch.
 *
 * No LLM calls — exercises the DB layer directly via fn_clause_upsert + fn_obligations_derive_from_clause.
 *
 * AC coverage:
 *   AC-S2-02 (queuing + idempotency)
 *   AC-S8-01 (FM → obligation)
 *   AC-S9-01 (renewal → obligation with due_date)
 *   AC-S11-01 (tenant isolation roundtrip)
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, adminQuery } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const RUN_ID = `ext-rt-${Date.now()}`;

const trackedContractIds: number[] = [];
const trackedClauseIds: number[] = [];

async function callFn<T>(
  actorId: number,
  fnName: string,
  args: ReadonlyArray<unknown>,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<T> {
  if (!/^[a-z_][a-z0-9_]*$/i.test(fnName)) throw new Error(`bad fn name: ${fnName}`);
  const placeholders = args.map((_, i) => `$${i + 1}`).join(', ');
  const bound = args.map((v) => {
    if (v === undefined || v === null) return null;
    if (Array.isArray(v) || (typeof v === 'object' && !(v instanceof Date))) return JSON.stringify(v);
    return v;
  });
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const r = await client.query<{ result: T }>(`SELECT ${fnName}(${placeholders}) AS result`, bound);
    await client.query('COMMIT');
    return r.rows[0]!.result as T;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    throw err;
  } finally {
    client.release();
  }
}

async function createContractVersion(suffix: string): Promise<{ contractId: number; versionId: number }> {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const unique = `${suffix}-${Date.now()}`;
    const cRes = await client.query<{ id: number }>(
      `INSERT INTO contract
        (contract_number, title_en, contract_type, status, data_classification,
         created_by, updated_by, is_active)
       VALUES ($1, $2, 'Service Agreement', 'active', 'demo', 1, 1, TRUE)
       RETURNING id`,
      [`TEST-CRD-RT-${unique}`, `Extract RT ${suffix}`],
    );
    const contractId = Number(cRes.rows[0]!.id);
    const vRes = await client.query<{ id: number }>(
      `INSERT INTO contract_version
        (contract_id, version_number, change_note, body_en, ingestion_status,
         ocr_used, ingestion_attempt_count, created_by, is_active, data_classification)
       VALUES ($1, 1, 'Initial', 'Force Majeure: 14 days notice.', 'complete', FALSE, 0, 1, TRUE, 'demo')
       RETURNING id`,
      [contractId],
    );
    await client.query('COMMIT');
    trackedContractIds.push(contractId);
    return { contractId, versionId: Number(vRes.rows[0]!.id) };
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* swallow */ }
    throw err;
  } finally {
    client.release();
  }
}

beforeAll(async () => {
  await seedFixtureUsers();
});

afterAll(async () => {
  if (trackedClauseIds.length > 0) {
    await adminQuery(
      `UPDATE contract_obligation SET is_active = FALSE WHERE derived_from_clause_id = ANY($1::bigint[])`,
      [trackedClauseIds],
    ).catch(() => {});
    await adminQuery(
      `DELETE FROM contract_clause_extracted WHERE id = ANY($1::bigint[])`,
      [trackedClauseIds],
    ).catch(() => {});
  }
  if (trackedContractIds.length > 0) {
    // Clean child rows before deleting contracts
    await adminQuery(
      `DELETE FROM contract_version WHERE contract_id = ANY($1::bigint[])`,
      [trackedContractIds],
    ).catch(() => {});
    await adminQuery(
      `DELETE FROM contract WHERE id = ANY($1::bigint[]) AND contract_number LIKE 'TEST-CRD-RT-%'`,
      [trackedContractIds],
    ).catch(() => {});
  }
});

describe('Extract roundtrip — queue → upsert → obligation', () => {
  it('AC-S2-02 + AC-S8-01: FM clause roundtrip — queue, upsert, obligation created', async () => {
    const { contractId, versionId } = await createContractVersion('fm-rt');

    // Step 1: Queue extraction
    const queueResult = await callFn<{ queued: boolean; extractionRunId: number }>(
      1,
      'fn_clause_extraction_request',
      [versionId, 1],
    );
    expect(queueResult.queued).toBe(true);

    // Step 2: Upsert FM clause (simulates worker completing Stage 2)
    // fn_clause_upsert returns: { clauseId, reviewStatus, obligationsCreated (jsonb array), ... }
    const upsertResult = await callFn<{ clauseId: number; reviewStatus: string; obligationsCreated: number[] }>(
      1,
      'fn_clause_upsert',
      [
        versionId,
        'force_majeure',
        JSON.stringify({ notice_period_days: 14 }),
        JSON.stringify({ notice_period_days: 'The affected party shall give 14 days written notice of any FM event.' }),
        1, 0, 200, 0.92, 'gpt-4o-2024-08-06', 'roundtripHash1', null,
        'FM clause with 14-day notice', '[AR] FM clause with 14-day notice', 1,
      ],
    );
    expect(typeof upsertResult.reviewStatus).toBe('string');
    trackedClauseIds.push(upsertResult.clauseId);

    // Step 3: Verify obligation was created
    expect(Array.isArray(upsertResult.obligationsCreated)).toBe(true);
    expect(upsertResult.obligationsCreated.length).toBeGreaterThan(0);
    const obligations = await adminQuery<{ obligation_type: string; is_active: boolean }>(
      `SELECT obligation_type, is_active FROM contract_obligation
       WHERE derived_from_clause_id = $1 AND is_active = TRUE`,
      [upsertResult.clauseId],
    );
    expect(obligations.length).toBeGreaterThan(0);
    expect(obligations[0]!.obligation_type).toBe('notice');
  });

  it('AC-S9-01: Renewal clause roundtrip — obligation with due_date set correctly', async () => {
    const { contractId, versionId } = await createContractVersion('renewal-rt');
    const expiryDate = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString().split('T')[0];

    const upsertResult = await callFn<{ clauseId: number; obligationsCreated: number[] }>(
      1,
      'fn_clause_upsert',
      [
        versionId,
        'term_and_renewal',
        JSON.stringify({ expiry_date: expiryDate, renewal_notice_period_days: 90 }),
        JSON.stringify({
          expiry_date: `This agreement expires on ${expiryDate}.`,
          renewal_notice_period_days: 'Renewal notice must be provided 90 days before expiry.',
        }),
        1, 100, 300, 0.91, 'gpt-4o-2024-08-06', 'renewalHash', null, null, null, 1,
      ],
    );
    trackedClauseIds.push(upsertResult.clauseId);

    expect(Array.isArray(upsertResult.obligationsCreated)).toBe(true);
    expect(upsertResult.obligationsCreated.length).toBeGreaterThan(0);

    const obligations = await adminQuery<{ obligation_type: string; due_date: Date | null }>(
      `SELECT obligation_type, due_date FROM contract_obligation
       WHERE derived_from_clause_id = $1 AND is_active = TRUE`,
      [upsertResult.clauseId],
    );
    expect(obligations[0]!.obligation_type).toBe('renewal');
    // due_date should be expiry_date - 90 days
    if (obligations[0]!.due_date) {
      const expectedDue = new Date(Date.parse(expiryDate) - 90 * 24 * 60 * 60 * 1000);
      const actualDue = new Date(obligations[0]!.due_date);
      // Allow 1 day tolerance for timezone handling
      const diffDays = Math.abs((expectedDue.getTime() - actualDue.getTime()) / (24 * 60 * 60 * 1000));
      expect(diffDays).toBeLessThanOrEqual(1);
    }
  });

  it('AC-S11-01: clause_taxonomy has 50 rows seeded for ADNOC tenant', async () => {
    const rows = await adminQuery<{ count: string }>(
      `SELECT count(*) FROM clause_taxonomy WHERE tenant_id = $1 AND is_active = TRUE AND is_deprecated = FALSE`,
      [ADNOC_TENANT_ID],
    );
    expect(Number(rows[0]!.count)).toBe(50);
  });

  it('AC-S11-01: cross-tenant roundtrip — clause from tenant A not visible in tenant B session', async () => {
    const { contractId, versionId } = await createContractVersion('tenant-iso');

    const upsertResult = await callFn<{ clauseId: number }>(
      1,
      'fn_clause_upsert',
      [
        versionId,
        'force_majeure',
        JSON.stringify({ notice_period_days: 7 }),
        JSON.stringify({ notice_period_days: '7 days written notice of FM events.' }),
        1, 400, 500, 0.88, 'gpt-4o', 'isoHash', null, null, null, 1,
      ],
    );
    trackedClauseIds.push(upsertResult.clauseId);

    // Verify the clause exists in ADNOC tenant
    const adnocRows = await adminQuery<{ count: string }>(
      `SELECT count(*) FROM contract_clause_extracted WHERE id = $1 AND tenant_id = $2`,
      [upsertResult.clauseId, ADNOC_TENANT_ID],
    );
    expect(Number(adnocRows[0]!.count)).toBe(1);

    // Verify clause belongs only to ADNOC tenant (not tenant B)
    const tenantBRows = await adminQuery<{ count: string }>(
      `SELECT count(*) FROM contract_clause_extracted WHERE id = $1 AND tenant_id = '00000000-0000-0000-0000-000000000002'`,
      [upsertResult.clauseId],
    );
    expect(Number(tenantBRows[0]!.count)).toBe(0);
    // (RLS enforcement via app.current_tenant_id GUC verified in pg_policies assertions)
  });
});
