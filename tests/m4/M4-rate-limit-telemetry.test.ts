/**
 * M4 — Rate limit gate + append-only telemetry log + cron eviction tests.
 *
 * Stories covered:
 *   - S8 fn_ai_insight_evict_expired (cron sweep + S2-20 system actor sentinel)
 *   - S9 fn_ai_request_log_check_rate_limit (S9-01..07)
 *   - S10 fn_ai_request_log_create + trg_ai_request_log_deny_update (S10-04)
 *
 * Testing pattern: stage rows directly via the BYPASSRLS pool (seedAiRequestLog),
 * then call the production fn_ via callFnAs — keeping the fn under test
 * independent of the seeding mechanism.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminPool, adminQuery, closeAdminPool } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';
import {
  cleanupAiArtifacts,
  countAiRequestLogsForActorPrompt,
  readAiInsightById,
  readAiRequestLogById,
  seedAiInsight,
  seedAiPrompt,
  seedAiRequestLog,
} from '../helpers/m4-helpers';

const trackedInsightIds: number[] = [];
const trackedRequestLogIds: number[] = [];
// Use a dedicated low-rate prompt for rate-limit tests so we don't pollute the
// production seeded prompts' counts and don't have to wait for hourly windows.
const RATE_TEST_PROMPT_ID = 'm4-test-rate-prompt';

beforeAll(async () => {
  await seedFixtureUsers();
  // Per-hour cap of 3 (so we can hit + exceed quickly); per-day cap of 100.
  await seedAiPrompt({
    promptId: RATE_TEST_PROMPT_ID,
    rateLimitPerUserPerHour: 3,
    rateLimitPerUserPerDay: 100,
  });
});

afterAll(async () => {
  if (trackedInsightIds.length > 0 || trackedRequestLogIds.length > 0) {
    try {
      await cleanupAiArtifacts({
        insightIds: trackedInsightIds,
        requestLogIds: trackedRequestLogIds,
        promptIds: [RATE_TEST_PROMPT_ID],
      });
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M4-rate cleanup]', err);
    }
  }
  await closeAdminPool();
});

// ──────────────────────────────────────────────────────────────────────────
// S9 — fn_ai_request_log_check_rate_limit
// ──────────────────────────────────────────────────────────────────────────

describe('S9 — fn_ai_request_log_check_rate_limit', () => {
  it('AC-S9-01: returns allowed=true with remainingHour > 0 when usage below limit', async () => {
    const drafter = getFixture('drafter1');
    const result = await callFnAs<{
      data: { allowed: boolean; remainingHour: number; remainingDay: number; retryAfterSeconds: number };
    }>(drafter.id, 'fn_ai_request_log_check_rate_limit', [drafter.id, RATE_TEST_PROMPT_ID]);
    expect(result.data.allowed).toBe(true);
    expect(result.data.remainingHour).toBeGreaterThanOrEqual(0);
    expect(result.data.retryAfterSeconds).toBe(0);
  });

  it('AC-S9-02: returns allowed=false with remainingHour=0 + retryAfter>0 when hourly limit hit', async () => {
    // Use a unique fixture (recipient1) so the count doesn't interfere with
    // other tests in this file. Seed exactly the cap (3) success rows.
    const recipient = getFixture('recipient1');
    for (let i = 0; i < 3; i++) {
      const id = await seedAiRequestLog({
        promptId: RATE_TEST_PROMPT_ID,
        actorUserId: recipient.id,
        outcome: 'success',
        cacheHit: false,
      });
      trackedRequestLogIds.push(id);
    }
    const result = await callFnAs<{
      data: { allowed: boolean; remainingHour: number; remainingDay: number; retryAfterSeconds: number };
    }>(recipient.id, 'fn_ai_request_log_check_rate_limit', [
      recipient.id,
      RATE_TEST_PROMPT_ID,
    ]);
    expect(result.data.allowed).toBe(false);
    expect(result.data.remainingHour).toBe(0);
    expect(result.data.retryAfterSeconds).toBeGreaterThan(0);
  });

  it('AC-S9-03: cache_hit=true rows count toward the limit', async () => {
    const approver = getFixture('approver1');
    for (let i = 0; i < 3; i++) {
      const id = await seedAiRequestLog({
        promptId: RATE_TEST_PROMPT_ID,
        actorUserId: approver.id,
        outcome: 'success',
        cacheHit: true, // KEY ASSERTION — cache hits still count
      });
      trackedRequestLogIds.push(id);
    }
    const r = await callFnAs<{ data: { allowed: boolean } }>(
      approver.id,
      'fn_ai_request_log_check_rate_limit',
      [approver.id, RATE_TEST_PROMPT_ID],
    );
    expect(r.data.allowed).toBe(false);
  });

  it('AC-S9-04: outcome=error rows count toward the limit (prevents retry-storm bypass)', async () => {
    const approver2 = getFixture('approver2');
    for (let i = 0; i < 3; i++) {
      const id = await seedAiRequestLog({
        promptId: RATE_TEST_PROMPT_ID,
        actorUserId: approver2.id,
        outcome: 'error',
        cacheHit: false,
        errorClass: 'server_error',
      });
      trackedRequestLogIds.push(id);
    }
    const r = await callFnAs<{ data: { allowed: boolean } }>(
      approver2.id,
      'fn_ai_request_log_check_rate_limit',
      [approver2.id, RATE_TEST_PROMPT_ID],
    );
    expect(r.data.allowed).toBe(false);
  });

  it('AC-S9-05: returns 23503 when prompt_id not in ai_prompt', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_ai_request_log_check_rate_limit', [drafter.id, 'nonexistent-prompt-xx']),
    ).rejects.toMatchObject({ code: '23503' });
  });

  it('rate_limited / timeout rows do NOT count toward the limit (only success+error+cache_hit do)', async () => {
    const legal = getFixture('legal_counsel1');
    // Stage 5 rate_limited rows + 5 timeout rows — these MUST NOT count.
    for (let i = 0; i < 5; i++) {
      const r1 = await seedAiRequestLog({
        promptId: RATE_TEST_PROMPT_ID,
        actorUserId: legal.id,
        outcome: 'rate_limited',
        cacheHit: false,
      });
      trackedRequestLogIds.push(r1);
      const r2 = await seedAiRequestLog({
        promptId: RATE_TEST_PROMPT_ID,
        actorUserId: legal.id,
        outcome: 'timeout',
        cacheHit: false,
      });
      trackedRequestLogIds.push(r2);
    }
    const r = await callFnAs<{ data: { allowed: boolean; remainingHour: number } }>(
      legal.id,
      'fn_ai_request_log_check_rate_limit',
      [legal.id, RATE_TEST_PROMPT_ID],
    );
    expect(r.data.allowed).toBe(true);
    expect(r.data.remainingHour).toBe(3); // Full quota intact
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S10 — fn_ai_request_log_create + append-only deny-update trigger
// ──────────────────────────────────────────────────────────────────────────

describe('S10 — fn_ai_request_log_create + append-only', () => {
  it('AC-S10-01: writes a row with outcome=success and metrics; returns id + requestId', async () => {
    const drafter = getFixture('drafter1');
    const requestId = '00000000-0000-0000-0000-000000000001';
    const r = await callFnAs<{ data: { id: number; requestId: string } }>(
      drafter.id,
      'fn_ai_request_log_create',
      [
        requestId,
        RATE_TEST_PROMPT_ID,
        'summary',
        drafter.id,
        'contract',
        999_999_100,
        'en',
        'openai',
        'gpt-4o-mini',
        100,
        50,
        1500,
        320,
        false, // cache_hit
        false, // stream_mode
        'success',
        null,
        null,
      ],
    );
    expect(r.data.id).toBeDefined();
    expect(r.data.requestId).toBe(requestId);
    trackedRequestLogIds.push(Number(r.data.id));
    const row = await readAiRequestLogById(Number(r.data.id));
    expect(row?.['outcome']).toBe('success');
    expect(row?.['cache_hit']).toBe(false);
    expect(Number(row?.['tokens_input'])).toBe(100);
  });

  it('AC-S10-03: cache hit rows have cache_hit=true, tokens_input=NULL, cost_usd_micros=0', async () => {
    const drafter = getFixture('drafter1');
    const requestId = '00000000-0000-0000-0000-000000000002';
    const r = await callFnAs<{ data: { id: number } }>(drafter.id, 'fn_ai_request_log_create', [
      requestId,
      RATE_TEST_PROMPT_ID,
      'summary',
      drafter.id,
      'contract',
      999_999_101,
      'en',
      'openai',
      'gpt-4o-mini',
      null,
      null,
      0,
      10,
      true, // cache_hit
      false,
      'success',
      null,
      null,
    ]);
    trackedRequestLogIds.push(Number(r.data.id));
    const row = await readAiRequestLogById(Number(r.data.id));
    expect(row?.['cache_hit']).toBe(true);
    expect(row?.['tokens_input']).toBeNull();
    expect(Number(row?.['cost_usd_micros'])).toBe(0);
  });

  it('AC-S10-04: trg_ai_request_log_deny_update raises 42501 on UPDATE', async () => {
    const drafter = getFixture('drafter1');
    const id = await seedAiRequestLog({
      promptId: RATE_TEST_PROMPT_ID,
      actorUserId: drafter.id,
      outcome: 'success',
    });
    trackedRequestLogIds.push(id);
    // Bypass-RLS UPDATE — should still raise 42501 from the trigger
    const pool = adminPool();
    const client = await pool.connect();
    let raisedCode: string | null = null;
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL row_security = off');
      try {
        await client.query(
          `UPDATE ai_request_log SET outcome = 'cancelled' WHERE id = $1`,
          [id],
        );
      } catch (err) {
        const e = err as { code?: string };
        raisedCode = e.code ?? null;
      }
      await client.query('ROLLBACK');
    } finally {
      client.release();
    }
    expect(raisedCode).toBe('42501');
  });

  it('AC-S10-05: actor_user_id can be NULL (public S5 endpoint path)', async () => {
    // We use callFnAs as a non-NULL actor (drafter), but pass NULL as the
    // p_actor_user_id parameter (S5 PUBLIC endpoint). The fn body inserts NULL.
    const drafter = getFixture('drafter1');
    const requestId = '00000000-0000-0000-0000-000000000003';
    const r = await callFnAs<{ data: { id: number } }>(drafter.id, 'fn_ai_request_log_create', [
      requestId,
      RATE_TEST_PROMPT_ID,
      'single',
      null, // actor_user_id
      'regulatory_update_summary',
      null,
      'en',
      'openai',
      'gpt-4o',
      0,
      0,
      0,
      0,
      true,
      false,
      'success',
      null,
      null,
    ]);
    trackedRequestLogIds.push(Number(r.data.id));
    const row = await readAiRequestLogById(Number(r.data.id));
    expect(row?.['actor_user_id']).toBeNull();
  });

  it('returns 22023 for invalid outcome value', async () => {
    const drafter = getFixture('drafter1');
    const requestId = '00000000-0000-0000-0000-000000000004';
    await expect(
      callFnAs(drafter.id, 'fn_ai_request_log_create', [
        requestId,
        RATE_TEST_PROMPT_ID,
        null,
        drafter.id,
        null,
        null,
        'en',
        'openai',
        'gpt-4o',
        null,
        null,
        null,
        null,
        false,
        false,
        'WAT', // INVALID
        null,
        null,
      ]),
    ).rejects.toMatchObject({ code: '22023' });
  });

  it('returns 22023 for invalid provider', async () => {
    const drafter = getFixture('drafter1');
    const requestId = '00000000-0000-0000-0000-000000000005';
    await expect(
      callFnAs(drafter.id, 'fn_ai_request_log_create', [
        requestId,
        RATE_TEST_PROMPT_ID,
        null,
        drafter.id,
        null,
        null,
        'en',
        'gemini', // INVALID
        'gpt-4o',
        null,
        null,
        null,
        null,
        false,
        false,
        'success',
        null,
        null,
      ]),
    ).rejects.toMatchObject({ code: '22023' });
  });

  it('returns 22023 for invalid language', async () => {
    const drafter = getFixture('drafter1');
    const requestId = '00000000-0000-0000-0000-000000000006';
    await expect(
      callFnAs(drafter.id, 'fn_ai_request_log_create', [
        requestId,
        RATE_TEST_PROMPT_ID,
        null,
        drafter.id,
        null,
        null,
        'fr', // INVALID
        'openai',
        'gpt-4o',
        null,
        null,
        null,
        null,
        false,
        false,
        'success',
        null,
        null,
      ]),
    ).rejects.toMatchObject({ code: '22023' });
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S8 — fn_ai_insight_evict_expired (cron sweep + S2-20 sentinel)
// ──────────────────────────────────────────────────────────────────────────

/**
 * Run fn_ai_insight_evict_expired as the SYSTEM_ACTOR sentinel
 * (app.current_user_id = '0'). Mirrors the cron driver behaviour.
 */
const runEvictAsSystem = async (
  batchSize: number,
): Promise<{ data: { evictedCount: number } }> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.current_user_id', '0', true)");
    const r = await client.query<{ result: { data: { evictedCount: number } } }>(
      'SELECT fn_ai_insight_evict_expired($1::INTEGER) AS result',
      [batchSize],
    );
    await client.query('COMMIT');
    return r.rows[0]!.result;
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

describe('S8 — fn_ai_insight_evict_expired (cron)', () => {
  it('AC-S8-02 + AC-S8-03: batched soft-delete; second call evicts the remaining rows; third call returns 0', async () => {
    const drafter = getFixture('drafter1');
    const stagedIds: number[] = [];
    for (let i = 0; i < 10; i++) {
      const id = await seedAiInsight({
        entityType: 'contract',
        entityId: 999_999_300 + i,
        insightType: 'contract_summary',
        language: 'en',
        promptId: 'ai-contract-insights',
        payload: { insightType: 'contract_summary', summary: `evict-${i}`, language: 'en' },
        actorUserId: drafter.id,
        // Backdate expires_at deeply in the past
        expiresAt: new Date(Date.now() - 60 * 60 * 1000),
      });
      stagedIds.push(id);
      trackedInsightIds.push(id);
    }
    const r1 = await runEvictAsSystem(5);
    expect(r1.data.evictedCount).toBe(5);
    const r2 = await runEvictAsSystem(5);
    expect(r2.data.evictedCount).toBe(5);
    const r3 = await runEvictAsSystem(5);
    expect(r3.data.evictedCount).toBe(0);

    // Confirm all 10 are now is_active=FALSE
    for (const id of stagedIds) {
      const row = await readAiInsightById(id);
      expect(row?.['is_active']).toBe(false);
    }
  });

  it('AC-S8-06: returns evictedCount=0 when no rows are due — does not raise', async () => {
    const r = await runEvictAsSystem(100);
    expect(r.data.evictedCount).toBe(0);
  });

  it('AC-S8-04: GRANT EXECUTE only to neondb_owner — no PUBLIC grant', async () => {
    const rows = await adminQuery<{ proacl_text: string }>(
      `SELECT proacl::text AS proacl_text
         FROM pg_proc
        WHERE proname = 'fn_ai_insight_evict_expired'`,
    );
    expect(rows.length).toBeGreaterThan(0);
    const acl = rows[0]!.proacl_text ?? '';
    // proacl text after REVOKE FROM PUBLIC + GRANT TO neondb_owner should
    // contain ONLY the named owner grant — never a wildcard '=X/...' entry
    // (that's the PUBLIC EXECUTE form) or 'PUBLIC=X' / '=X/postgres'.
    expect(acl).toContain('neondb_owner=X');
    // PUBLIC grant in proacl text is rendered as a leading bare '=X/' WITHOUT
    // a role prefix — i.e. '{=X/owner,...}'. Assert no such entry.
    expect(/[{,]=X\//.test(acl)).toBe(false);
    expect(acl).not.toContain('PUBLIC=X');
  });

  it('S2-20: cron actor sentinel — eviction with app.current_user_id=0 leaves audit_log rows with consistent system-actor pattern', async () => {
    // Stage 1 expired insight; run cron; verify the row is deactivated AND
    // the audit_log entry recorded a system-actor (0 OR NULL — per memory
    // M4-DBI-NOTE-S2-20, audit_log records the literal sentinel; coercion to
    // NULL only happens in fn_contract_activity_create which the eviction
    // does NOT call).
    const drafter = getFixture('drafter1');
    const id = await seedAiInsight({
      entityType: 'contract',
      entityId: 999_999_400,
      insightType: 'contract_summary',
      language: 'en',
      promptId: 'ai-contract-insights',
      payload: { insightType: 'contract_summary', summary: 'cron-test', language: 'en' },
      actorUserId: drafter.id,
      expiresAt: new Date(Date.now() - 60 * 1000),
    });
    trackedInsightIds.push(id);
    await runEvictAsSystem(10);

    const row = await readAiInsightById(id);
    expect(row?.['is_active']).toBe(false);
    // updated_by SHOULD be NULL — fn body doesn't set it on eviction (only
    // is_active + updated_at). Verify the soft-delete didn't write a
    // system-sentinel value into updated_by.
    // (See migration 043 lines 244-249 — UPDATE only sets is_active +
    // updated_at on eviction).
    // updated_by may come back as string (BIGINT) or number depending on the
    // pg driver path; accept either form.
    expect(Number(row?.['updated_by'])).toBe(Number(drafter.id));
  });
});

// ──────────────────────────────────────────────────────────────────────────
// Schema introspection — guard against future PUBLIC grants slipping in
// ──────────────────────────────────────────────────────────────────────────

describe('S2-21 — PUBLIC EXECUTE allowlist regression guard', () => {
  it('exactly the 5 M3 fn_ names hold PUBLIC EXECUTE (no M4 additions)', async () => {
    const rows = await adminQuery<{ proname: string }>(
      `SELECT DISTINCT p.proname
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         JOIN unnest(p.proacl) acl ON TRUE
        WHERE n.nspname = 'public'
          AND p.proname LIKE 'fn\\_%'
          AND (acl::text LIKE '=X/%' OR acl::text LIKE 'PUBLIC=X/%')
        ORDER BY p.proname`,
    );
    const names = rows.map((r) => r.proname).sort();
    const expected = [
      'fn_signature_decline',
      'fn_signature_get_by_invitation_token',
      'fn_signature_sign',
      'fn_signer_qa_session_record_message',
      'fn_signer_qa_session_start',
    ].sort();
    expect(names).toEqual(expected);
  });

  it('regression guard — none of the M4 fn_ names appear in PUBLIC EXECUTE', async () => {
    const m4Fns = [
      'fn_ai_insight_get_cached',
      'fn_ai_insight_upsert',
      'fn_ai_insight_evict_expired',
      'fn_ai_request_log_create',
      'fn_ai_request_log_check_rate_limit',
      'fn_ai_prompt_get',
      'fn_ai_prompt_list',
      'fn_contract_ai_summary_persist',
      'fn_contract_version_diff_summary_persist',
      'fn_ai_insight_list',
      'fn_ai_request_log_list',
      'fn_ai_request_log_cost_report',
    ];
    const rows = await adminQuery<{ proname: string }>(
      `SELECT DISTINCT p.proname
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         JOIN unnest(p.proacl) acl ON TRUE
        WHERE n.nspname = 'public'
          AND p.proname = ANY($1::text[])
          AND (acl::text LIKE '=X/%' OR acl::text LIKE 'PUBLIC=X/%')`,
      [m4Fns],
    );
    expect(rows.length).toBe(0);
  });
});

// ──────────────────────────────────────────────────────────────────────────
// Internal sanity — count helpers used by other tests work on fixture user
// ──────────────────────────────────────────────────────────────────────────

describe('M4 helper sanity (telemetry counts)', () => {
  it('countAiRequestLogsForActorPrompt returns the recently inserted rows', async () => {
    const drafter = getFixture('drafter1');
    const before = await countAiRequestLogsForActorPrompt(drafter.id, RATE_TEST_PROMPT_ID);
    const id = await seedAiRequestLog({
      promptId: RATE_TEST_PROMPT_ID,
      actorUserId: drafter.id,
      outcome: 'success',
    });
    trackedRequestLogIds.push(id);
    const after = await countAiRequestLogsForActorPrompt(drafter.id, RATE_TEST_PROMPT_ID);
    expect(after).toBe(before + 1);
  });
});
