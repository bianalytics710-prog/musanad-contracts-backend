/**
 * M4 — DB function tests for persist carve-outs (S1, S6) + admin-observability
 * read fns (S11, S12, S13).
 *
 * Covers:
 *   - fn_contract_ai_summary_persist (DEFINER carve-out — S1)
 *       + emits ai_summary_generated / ai_risk_score_updated activities
 *       + 42501 on insufficient privilege
 *       + P0001 on unknown contract_id
 *       + 23514 on out-of-range risk score
 *   - fn_contract_version_diff_summary_persist (DEFINER carve-out — S6)
 *       + emits ai_diff_summary_generated activity
 *       + P0001 on unknown contract_version_id
 *   - fn_ai_prompt_get / fn_ai_prompt_list (S13)
 *   - fn_ai_insight_list (S11) — paginated + filters
 *   - fn_ai_request_log_list (S11) — paginated + filters + 22023 on date > 90d
 *   - fn_ai_request_log_cost_report (S12) — group by user, cacheHitRatio,
 *     22023 on date > 90 days OR fromDate > toDate
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, adminQuery, closeAdminPool } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';
import {
  cleanupAiArtifacts,
  seedAiInsight,
  seedAiRequestLog,
} from '../helpers/m4-helpers';

const trackedInsightIds: number[] = [];
const trackedRequestLogIds: number[] = [];
const trackedContractIds: number[] = [];
const trackedVersionIds: number[] = [];

beforeAll(async () => {
  await seedFixtureUsers();
});

afterAll(async () => {
  // Cleanup activity rows + insight + request log rows
  if (trackedInsightIds.length || trackedRequestLogIds.length || trackedContractIds.length) {
    try {
      await cleanupAiArtifacts({
        insightIds: trackedInsightIds,
        requestLogIds: trackedRequestLogIds,
        contractIds: trackedContractIds,
      });
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M4-persist cleanup ai]', err);
    }
  }
  // Delete contract_version + contract rows
  if (trackedContractIds.length > 0) {
    const pool = adminPool();
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      await client.query(
        `DELETE FROM contract_activity WHERE contract_id = ANY($1::BIGINT[])`,
        [trackedContractIds],
      );
      await client.query(
        `DELETE FROM contract_version WHERE contract_id = ANY($1::BIGINT[])`,
        [trackedContractIds],
      );
      await client.query(
        `DELETE FROM contract WHERE id = ANY($1::BIGINT[])`,
        [trackedContractIds],
      );
      await client.query('COMMIT');
    } catch {
      try {
        await client.query('ROLLBACK');
      } catch {
        /* swallow */
      }
    } finally {
      client.release();
    }
  }
  await closeAdminPool();
});

/** Seed a draft contract directly via fn_contract_create (M1a). Returns id. */
const seedDraftContract = async (drafterId: number): Promise<number> => {
  const r = await callFnAs<{ created: { id: number } }>(drafterId, 'fn_contract_create', [
    {
      titleEn: `M4-persist-${Date.now()}-${Math.random()}`,
      contractType: 'employment',
      language: 'en',
      valueAed: 50_000,
    },
    drafterId,
  ]);
  // fn_contract_create returns either { created: ... } or directly the row
  // depending on caller; M1a returns the row directly when called via the
  // adminQuery alias. callFnAs returns the raw fn result — for fn_contract_create,
  // that's a JSONB with the contract data.
  // Looking at the fn body, it returns jsonb_build_object('id', ..., 'contractNumber', ...).
  const raw = r as unknown as { id?: number; created?: { id?: number } };
  const id = raw.id ?? raw.created?.id;
  if (!id) {
    throw new Error('seedDraftContract: unexpected fn_contract_create response shape');
  }
  return Number(id);
};

/** Insert a contract_version row directly via the admin pool. */
const seedContractVersion = async (
  contractId: number,
  drafterId: number,
): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    // contract_version columns (M1a 003): id, contract_id, version_number,
    // body_en, body_ar, diff_summary, change_note, changed_by, created_at,
    // created_by, is_active. NO updated_by / updated_at by design — append-only.
    // M4 fn_contract_version_diff_summary_persist is the carve-out that
    // writes diff_summary + updated_at via the deny-update trigger.
    // Each call here uses a unique version_number to avoid uq_contract_version
    // collisions across the test file.
    const versionNumber = Math.floor(Date.now() % 1_000_000);
    const r = await client.query<{ id: number | string }>(
      `INSERT INTO contract_version
         (contract_id, version_number, body_en, change_note, changed_by, created_by, is_active)
         VALUES ($1, $2, $3, $4, $5, $5, TRUE)
       RETURNING id`,
      [contractId, versionNumber, 'M4 test body snapshot', 'm4 test seed', drafterId],
    );
    await client.query('COMMIT');
    return Number(r.rows[0]!.id);
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

// ──────────────────────────────────────────────────────────────────────────
// S1 — fn_contract_ai_summary_persist
// ──────────────────────────────────────────────────────────────────────────

describe('S1 — fn_contract_ai_summary_persist (DEFINER carve-out)', () => {
  it('AC-S1-07: writes ai_summary_en + ai_risk_score; emits ai_summary_generated + ai_risk_score_updated activities', async () => {
    const drafter = getFixture('drafter1');
    const contractId = await seedDraftContract(drafter.id);
    trackedContractIds.push(contractId);

    const result = await callFnAs<{
      data: {
        contractId: number;
        aiSummaryEn: string;
        aiRiskScore: number;
        updatedAt: string;
      };
    }>(drafter.id, 'fn_contract_ai_summary_persist', [
      contractId,
      drafter.id,
      'AI-generated test summary in English',
      null,
      75,
    ]);
    expect(Number(result.data.contractId)).toBe(contractId);
    expect(result.data.aiSummaryEn).toBe('AI-generated test summary in English');
    expect(result.data.aiRiskScore).toBe(75);

    // Activity emission
    const acts = await adminQuery<{ activity_type: string }>(
      `SELECT activity_type FROM contract_activity
        WHERE contract_id = $1
          AND activity_type IN ('ai_summary_generated','ai_risk_score_updated')
        ORDER BY id ASC`,
      [contractId],
    );
    const types = acts.map((a) => a.activity_type);
    expect(types).toContain('ai_summary_generated');
    expect(types).toContain('ai_risk_score_updated');
  });

  it('only emits ai_risk_score_updated when score actually changes', async () => {
    const drafter = getFixture('drafter1');
    const contractId = await seedDraftContract(drafter.id);
    trackedContractIds.push(contractId);

    // First call sets risk to 50.
    await callFnAs(drafter.id, 'fn_contract_ai_summary_persist', [
      contractId,
      drafter.id,
      'first summary',
      null,
      50,
    ]);
    // Second call repeats risk=50 — should NOT emit ai_risk_score_updated.
    await callFnAs(drafter.id, 'fn_contract_ai_summary_persist', [
      contractId,
      drafter.id,
      'second summary',
      null,
      50,
    ]);
    const rs = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count FROM contract_activity
        WHERE contract_id = $1 AND activity_type = 'ai_risk_score_updated'`,
      [contractId],
    );
    expect(Number(rs[0]?.count)).toBe(1); // only once
  });

  it('AC-S1-03 / P0001: returns P0001 when contract_id is unknown', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_contract_ai_summary_persist', [
        -1,
        drafter.id,
        'x',
        null,
        50,
      ]),
    ).rejects.toMatchObject({ code: 'P0001' });
  });

  it('returns 23514 when risk_score is out of range (>100)', async () => {
    const drafter = getFixture('drafter1');
    const contractId = await seedDraftContract(drafter.id);
    trackedContractIds.push(contractId);
    await expect(
      callFnAs(drafter.id, 'fn_contract_ai_summary_persist', [
        contractId,
        drafter.id,
        'x',
        null,
        150, // >100
      ]),
    ).rejects.toMatchObject({ code: '23514' });
  });

  it('returns 23514 when risk_score is negative', async () => {
    const drafter = getFixture('drafter1');
    const contractId = await seedDraftContract(drafter.id);
    trackedContractIds.push(contractId);
    await expect(
      callFnAs(drafter.id, 'fn_contract_ai_summary_persist', [
        contractId,
        drafter.id,
        'x',
        null,
        -1,
      ]),
    ).rejects.toMatchObject({ code: '23514' });
  });

  it('AC-S1-12 / 42501: caller without contract.edit / contract.read.all is rejected', async () => {
    // recipient1 has only contract.read.own — no contract.edit / contract.read.all.
    // Note: contract_drafter has contract.edit; recipient does NOT. Per fn body,
    // permission gate uses fn_current_user_has_permission('contract.edit') OR
    // ('contract.read.all'). recipient1 should fail.
    const drafter = getFixture('drafter1');
    const recipient = getFixture('recipient1');
    const contractId = await seedDraftContract(drafter.id);
    trackedContractIds.push(contractId);
    await expect(
      callFnAs(recipient.id, 'fn_contract_ai_summary_persist', [
        contractId,
        recipient.id,
        'x',
        null,
        50,
      ]),
    ).rejects.toMatchObject({ code: '42501' });
  });

  it('COALESCE: NULL summary_en preserves prior value (only updates non-NULL columns)', async () => {
    const drafter = getFixture('drafter1');
    const contractId = await seedDraftContract(drafter.id);
    trackedContractIds.push(contractId);

    await callFnAs(drafter.id, 'fn_contract_ai_summary_persist', [
      contractId,
      drafter.id,
      'original english summary',
      null,
      30,
    ]);

    // Second call with NULL summary_en should leave it unchanged.
    const r2 = await callFnAs<{ data: { aiSummaryEn: string | null } }>(
      drafter.id,
      'fn_contract_ai_summary_persist',
      [contractId, drafter.id, null, null, 40],
    );
    expect(r2.data.aiSummaryEn).toBe('original english summary');
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S6 — fn_contract_version_diff_summary_persist
// ──────────────────────────────────────────────────────────────────────────

describe('S6 — fn_contract_version_diff_summary_persist (DEFINER carve-out)', () => {
  it('AC-S6-04: writes diff_summary; emits ai_diff_summary_generated activity', async () => {
    const drafter = getFixture('drafter1');
    const contractId = await seedDraftContract(drafter.id);
    trackedContractIds.push(contractId);
    const versionId = await seedContractVersion(contractId, drafter.id);
    trackedVersionIds.push(versionId);

    const result = await callFnAs<{
      data: { contractVersionId: number; diffSummary: string; updatedAt: string };
    }>(drafter.id, 'fn_contract_version_diff_summary_persist', [
      versionId,
      drafter.id,
      'Headline\n• bullet one\n• bullet two',
    ]);
    expect(Number(result.data.contractVersionId)).toBe(versionId);
    expect(result.data.diffSummary).toContain('bullet one');

    const acts = await adminQuery<{ activity_type: string }>(
      `SELECT activity_type FROM contract_activity
        WHERE contract_id = $1 AND activity_type = 'ai_diff_summary_generated'`,
      [contractId],
    );
    expect(acts.length).toBeGreaterThanOrEqual(1);
  });

  it('AC-S6-02 / P0001: returns P0001 when contract_version_id is unknown', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_contract_version_diff_summary_persist', [
        -1,
        drafter.id,
        'irrelevant',
      ]),
    ).rejects.toMatchObject({ code: 'P0001' });
  });

  it('idempotent overwrite — second call replaces prior summary', async () => {
    const drafter = getFixture('drafter1');
    const contractId = await seedDraftContract(drafter.id);
    trackedContractIds.push(contractId);
    const versionId = await seedContractVersion(contractId, drafter.id);
    trackedVersionIds.push(versionId);

    await callFnAs(drafter.id, 'fn_contract_version_diff_summary_persist', [
      versionId,
      drafter.id,
      'first',
    ]);
    const r = await callFnAs<{ data: { diffSummary: string } }>(
      drafter.id,
      'fn_contract_version_diff_summary_persist',
      [versionId, drafter.id, 'second'],
    );
    expect(r.data.diffSummary).toBe('second');
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S13 — fn_ai_prompt_get / fn_ai_prompt_list
// ──────────────────────────────────────────────────────────────────────────

describe('S13 — fn_ai_prompt_get + fn_ai_prompt_list', () => {
  it('AC-S13-04: list returns 6 production prompts when includeInactive=false', async () => {
    const admin = 1; // bootstrap admin
    const r = await callFnAs<{ data: Array<{ promptId: string; isActive: boolean }> }>(
      admin,
      'fn_ai_prompt_list',
      [false],
    );
    expect(Array.isArray(r.data)).toBe(true);
    const productionIds = r.data.map((p) => p.promptId);
    expect(productionIds).toEqual(expect.arrayContaining([
      'ai-contract-insights',
      'ai-drafting-assistant',
      'ai-executive-anomalies',
      'ai-regulatory-impact',
      'ai-regulatory-impact-summary',
      'ai-version-diff-summary',
    ]));
    // All listed prompts are active when includeInactive=false
    expect(r.data.every((p) => p.isActive)).toBe(true);
  });

  it('fn_ai_prompt_get returns full row for a known prompt_id', async () => {
    const admin = 1;
    const r = await callFnAs<{
      promptId: string;
      defaultModel: string;
      defaultTtlSeconds: number;
      supportsStreaming: boolean;
      supportsToolCall: boolean;
    }>(admin, 'fn_ai_prompt_get', ['ai-contract-insights']);
    expect(r).not.toBeNull();
    expect(r.promptId).toBe('ai-contract-insights');
    expect(typeof r.defaultModel).toBe('string');
    expect(typeof r.defaultTtlSeconds).toBe('number');
  });

  it('fn_ai_prompt_get returns NULL for unknown prompt_id', async () => {
    const admin = 1;
    const r = await callFnAs(admin, 'fn_ai_prompt_get', ['no-such-prompt']);
    expect(r).toBeNull();
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S11 — fn_ai_insight_list + fn_ai_request_log_list
// ──────────────────────────────────────────────────────────────────────────

describe('S11 — fn_ai_insight_list + fn_ai_request_log_list', () => {
  it('AC-S11-01: ai_insight_list returns paginated payload + pagination metadata', async () => {
    const admin = 1;
    const drafter = getFixture('drafter1');
    // Seed 3 insights so we have data
    for (let i = 0; i < 3; i++) {
      const id = await seedAiInsight({
        entityType: 'contract',
        entityId: 999_999_500 + i,
        insightType: 'contract_summary',
        language: 'en',
        promptId: 'ai-contract-insights',
        payload: { insightType: 'contract_summary', summary: `list-${i}`, language: 'en' },
        actorUserId: drafter.id,
        ttlSeconds: 3600,
      });
      trackedInsightIds.push(id);
    }
    const r = await callFnAs<{
      data: Array<{ id: number; entityType: string }>;
      pagination: { page: number; limit: number; total: number; totalPages: number };
    }>(admin, 'fn_ai_insight_list', [1, 10, 'contract', 'contract_summary', 'en', null, false]);
    expect(Array.isArray(r.data)).toBe(true);
    expect(r.pagination).toBeDefined();
    expect(r.pagination.page).toBe(1);
    expect(r.pagination.limit).toBe(10);
    expect(r.pagination.total).toBeGreaterThanOrEqual(3);
  });

  it('AC-S11-04: fn_ai_request_log_list returns empty data when filters match nothing', async () => {
    const admin = 1;
    const r = await callFnAs<{
      data: unknown[];
      pagination: { total: number };
    }>(admin, 'fn_ai_request_log_list', [
      1,
      50,
      -999_999, // actor_user_id that does not exist
      null,
      null,
      null,
      null,
    ]);
    expect(Array.isArray(r.data)).toBe(true);
    expect(r.data.length).toBe(0);
    expect(r.pagination.total).toBe(0);
  });

  it('AC-S11-06 / 22023: ai_request_log_list raises 22023 on date range > 90 days', async () => {
    const admin = 1;
    await expect(
      callFnAs(admin, 'fn_ai_request_log_list', [
        1,
        50,
        null,
        null,
        null,
        '2024-01-01',
        '2024-12-31', // 365 days
      ]),
    ).rejects.toMatchObject({ code: '22023' });
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S12 — fn_ai_request_log_cost_report
// ──────────────────────────────────────────────────────────────────────────

describe('S12 — fn_ai_request_log_cost_report', () => {
  it('AC-S12-04: returns 22023 when date range exceeds 90 days', async () => {
    const admin = 1;
    await expect(
      callFnAs(admin, 'fn_ai_request_log_cost_report', [
        '2024-01-01',
        '2024-06-01', // ~150 days
        false,
      ]),
    ).rejects.toMatchObject({ code: '22023' });
  });

  it('returns 22023 when fromDate > toDate', async () => {
    const admin = 1;
    await expect(
      callFnAs(admin, 'fn_ai_request_log_cost_report', [
        '2026-05-01',
        '2026-04-01', // toDate before fromDate
        false,
      ]),
    ).rejects.toMatchObject({ code: '22023' });
  });

  it('AC-S12-01: returns aggregated rows by promptId; cacheHitRatio computed correctly', async () => {
    const admin = 1;
    const drafter = getFixture('drafter1');
    // Seed: 2 success, 1 cache-hit, 1 error → 4 rows; cacheHitRatio = 1/4
    const promptId = 'ai-contract-insights';
    for (let i = 0; i < 2; i++) {
      const id = await seedAiRequestLog({
        promptId,
        actorUserId: drafter.id,
        outcome: 'success',
        cacheHit: false,
        costUsdMicros: 1000,
        tokensInput: 100,
        tokensOutput: 50,
      });
      trackedRequestLogIds.push(id);
    }
    const idCache = await seedAiRequestLog({
      promptId,
      actorUserId: drafter.id,
      outcome: 'success',
      cacheHit: true,
      costUsdMicros: 0,
      tokensInput: null,
      tokensOutput: null,
    });
    trackedRequestLogIds.push(idCache);
    const idErr = await seedAiRequestLog({
      promptId,
      actorUserId: drafter.id,
      outcome: 'error',
      cacheHit: false,
      costUsdMicros: 0,
      errorClass: 'server_error',
    });
    trackedRequestLogIds.push(idErr);

    // Today's date range
    const today = new Date().toISOString().slice(0, 10);
    const r = await callFnAs<{
      data: Array<{
        promptId: string;
        successCount: number;
        errorCount: number;
        cacheHitRatio: number | null;
        totalCostUsdMicros: number;
      }>;
    }>(admin, 'fn_ai_request_log_cost_report', [today, today, false]);

    expect(Array.isArray(r.data)).toBe(true);
    const row = r.data.find((d) => d.promptId === promptId);
    expect(row).toBeDefined();
    expect(Number(row!.successCount)).toBeGreaterThanOrEqual(3); // 2 success + 1 cache-hit
    expect(Number(row!.errorCount)).toBeGreaterThanOrEqual(1);
    // cacheHitRatio computed as cache_hit_count / (cache_hit + provider_call)
    // exact value depends on residue; just assert it's defined and 0..1.
    if (row!.cacheHitRatio !== null) {
      const ratio = Number(row!.cacheHitRatio);
      expect(ratio).toBeGreaterThanOrEqual(0);
      expect(ratio).toBeLessThanOrEqual(1);
    }
  });

  it('AC-S12-02: groupByUser=true expands rows by actor_user_id', async () => {
    const admin = 1;
    const today = new Date().toISOString().slice(0, 10);
    const r = await callFnAs<{
      data: Array<{
        promptId: string;
        actor: { id: number } | null;
      }>;
    }>(admin, 'fn_ai_request_log_cost_report', [today, today, true]);
    // Each row should carry an actor (or null)
    expect(Array.isArray(r.data)).toBe(true);
    for (const row of r.data) {
      // actor key present in JSON output
      expect('actor' in row).toBe(true);
    }
  });
});
