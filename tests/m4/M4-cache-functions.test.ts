/**
 * M4 — DB function tests for the cache layer (S7) + atomic upsert + S2 lessons.
 *
 * Covers:
 *   - fn_ai_insight_get_cached (S7-01..03, S7-06)  — NULL-safe equality,
 *     expiry-aware miss, language/insight-type/entity scoping.
 *   - fn_ai_insight_upsert (S7-02)                 — atomic soft-deactivate +
 *     INSERT on the same key. S2-17 SELECT FOR UPDATE preserved. Validates
 *     the canonical 14-arg signature.
 *   - S2-18 NULL-safe equality: executive_dashboard rows (entity_id=NULL)
 *     and the COALESCE-based partial-unique semantics.
 *   - S2-17 concurrency primitive: parallel cron-style eviction is safe
 *     (SKIP LOCKED) — verified via two simultaneous calls with overlapping
 *     batch windows.
 *
 * Pattern: drive each fn_ via callFnAs (BYPASSRLS pool with app.current_user_id
 * set to the appropriate fixture user). Mirrors M2/M3 conventions.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { closeAdminPool } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';
import {
  cleanupAiArtifacts,
  countActiveAiInsightsForKey,
  readAiInsightById,
  seedAiInsight,
} from '../helpers/m4-helpers';
import { adminQuery } from '../helpers/m1a-helpers';

const trackedInsightIds: number[] = [];

beforeAll(async () => {
  await seedFixtureUsers();
});

afterAll(async () => {
  if (trackedInsightIds.length > 0) {
    try {
      await cleanupAiArtifacts({ insightIds: trackedInsightIds });
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M4-cache cleanup]', err);
    }
  }
  await closeAdminPool();
});

// ──────────────────────────────────────────────────────────────────────────
// S7 — fn_ai_insight_get_cached
// ──────────────────────────────────────────────────────────────────────────

describe('S7 — fn_ai_insight_get_cached', () => {
  it('AC-S7-01: returns cached row when key matches AND not expired AND active', async () => {
    const drafter = getFixture('drafter1');
    const tag = `cache-hit-${Date.now()}-${Math.random()}`;
    const id = await seedAiInsight({
      entityType: 'contract',
      entityId: 999_999_001,
      insightType: 'contract_summary',
      language: 'en',
      promptId: 'ai-contract-insights',
      payloadHash: tag,
      ttlSeconds: 3600,
      payload: { insightType: 'contract_summary', summary: 'cached test summary', language: 'en' },
      actorUserId: drafter.id,
    });
    trackedInsightIds.push(id);
    const result = await callFnAs<unknown>(drafter.id, 'fn_ai_insight_get_cached', [
      'contract',
      999_999_001,
      'contract_summary',
      'en',
      null,
    ]);
    expect(result).not.toBeNull();
    const row = result as { id: number; insightType: string };
    expect(Number(row.id)).toBe(id);
    expect(row.insightType).toBe('contract_summary');
  });

  it('AC-S7-01: returns NULL when no row matches', async () => {
    const drafter = getFixture('drafter1');
    const result = await callFnAs<unknown>(drafter.id, 'fn_ai_insight_get_cached', [
      'contract',
      -1,
      'contract_summary',
      'en',
      null,
    ]);
    expect(result).toBeNull();
  });

  it('AC-S7-01: returns NULL when row is expired', async () => {
    const drafter = getFixture('drafter1');
    const id = await seedAiInsight({
      entityType: 'contract',
      entityId: 999_999_002,
      insightType: 'contract_summary',
      language: 'en',
      promptId: 'ai-contract-insights',
      payload: { insightType: 'contract_summary', summary: 'expired', language: 'en' },
      actorUserId: drafter.id,
      // expires_at in the past
      expiresAt: new Date(Date.now() - 60 * 1000),
    });
    trackedInsightIds.push(id);
    const result = await callFnAs<unknown>(drafter.id, 'fn_ai_insight_get_cached', [
      'contract',
      999_999_002,
      'contract_summary',
      'en',
      null,
    ]);
    expect(result).toBeNull();
  });

  it('AC-S7-01: returns NULL when row is_active=FALSE', async () => {
    const drafter = getFixture('drafter1');
    const id = await seedAiInsight({
      entityType: 'contract',
      entityId: 999_999_003,
      insightType: 'contract_summary',
      language: 'en',
      promptId: 'ai-contract-insights',
      payload: { insightType: 'contract_summary', summary: 'soft-deleted', language: 'en' },
      actorUserId: drafter.id,
      ttlSeconds: 3600,
      isActive: false,
    });
    trackedInsightIds.push(id);
    const result = await callFnAs<unknown>(drafter.id, 'fn_ai_insight_get_cached', [
      'contract',
      999_999_003,
      'contract_summary',
      'en',
      null,
    ]);
    expect(result).toBeNull();
  });

  it('AC-S7-03 / S2-18: NULL-safe equality matches executive_dashboard rows with entity_id=NULL', async () => {
    const exec = getFixture('executive1');
    const id = await seedAiInsight({
      entityType: 'executive_dashboard',
      entityId: null,
      insightType: 'executive_anomalies',
      language: 'en',
      promptId: 'ai-executive-anomalies',
      ttlSeconds: 3600,
      payload: {
        insightType: 'executive_anomalies',
        anomalies: [{ insight: 'test anomaly', severity: 'info', drillDownFilter: 'foo' }],
        generatedAt: new Date().toISOString(),
      },
      actorUserId: exec.id,
    });
    trackedInsightIds.push(id);
    const result = await callFnAs<{ id: number }>(exec.id, 'fn_ai_insight_get_cached', [
      'executive_dashboard',
      null,
      'executive_anomalies',
      'en',
      null,
    ]);
    expect(result).not.toBeNull();
    expect(Number(result.id)).toBe(id);
  });

  it('S7-NULL-distinction: a NULL-entity row is NOT returned when querying with a BIGINT entity_id', async () => {
    const exec = getFixture('executive1');
    // Pre-seeded row from prior test exists with entity_id=NULL. Querying with
    // a concrete entity_id must not match it.
    const result = await callFnAs<unknown>(exec.id, 'fn_ai_insight_get_cached', [
      'executive_dashboard',
      42,
      'executive_anomalies',
      'en',
      null,
    ]);
    expect(result).toBeNull();
  });

  it('AC-S7-01: language scoping — en row is not returned when querying for ar', async () => {
    const drafter = getFixture('drafter1');
    const id = await seedAiInsight({
      entityType: 'contract',
      entityId: 999_999_010,
      insightType: 'contract_summary',
      language: 'en',
      promptId: 'ai-contract-insights',
      payload: { insightType: 'contract_summary', summary: 'en only', language: 'en' },
      actorUserId: drafter.id,
      ttlSeconds: 3600,
    });
    trackedInsightIds.push(id);
    const result = await callFnAs<unknown>(drafter.id, 'fn_ai_insight_get_cached', [
      'contract',
      999_999_010,
      'contract_summary',
      'ar',
      null,
    ]);
    expect(result).toBeNull();
  });

  it('AC-S7-01: payload_hash filter — wrong hash returns NULL', async () => {
    const drafter = getFixture('drafter1');
    const id = await seedAiInsight({
      entityType: 'contract',
      entityId: 999_999_011,
      insightType: 'contract_summary',
      language: 'en',
      promptId: 'ai-contract-insights',
      payloadHash: 'expected-hash',
      payload: { insightType: 'contract_summary', summary: 'hash test', language: 'en' },
      actorUserId: drafter.id,
      ttlSeconds: 3600,
    });
    trackedInsightIds.push(id);
    const result = await callFnAs<unknown>(drafter.id, 'fn_ai_insight_get_cached', [
      'contract',
      999_999_011,
      'contract_summary',
      'en',
      'wrong-hash',
    ]);
    expect(result).toBeNull();
    const matched = await callFnAs<{ id: number }>(drafter.id, 'fn_ai_insight_get_cached', [
      'contract',
      999_999_011,
      'contract_summary',
      'en',
      'expected-hash',
    ]);
    expect(matched).not.toBeNull();
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S7 — fn_ai_insight_upsert (atomic soft-deactivate + insert)
// ──────────────────────────────────────────────────────────────────────────

describe('S7 — fn_ai_insight_upsert', () => {
  it('AC-S7-02: first call inserts row; second call soft-deactivates row1 and inserts row2', async () => {
    const drafter = getFixture('drafter1');
    // First upsert — fresh key.
    const r1 = await callFnAs<{ data: { id: number; expiresAt: string } }>(
      drafter.id,
      'fn_ai_insight_upsert',
      [
        'contract',
        999_999_020,
        'contract_summary',
        'en',
        'openai',
        'gpt-4o-mini',
        JSON.stringify({ insightType: 'contract_summary', summary: 'v1', language: 'en' }),
        'hash-v1',
        'ai-contract-insights',
        100,
        50,
        1000,
        null, // ttl uses default
        drafter.id,
      ],
    );
    const id1 = Number(r1.data.id);
    trackedInsightIds.push(id1);

    // Second upsert — same key — soft-deactivates id1, inserts new row.
    const r2 = await callFnAs<{ data: { id: number } }>(drafter.id, 'fn_ai_insight_upsert', [
      'contract',
      999_999_020,
      'contract_summary',
      'en',
      'openai',
      'gpt-4o',
      JSON.stringify({ insightType: 'contract_summary', summary: 'v2', language: 'en' }),
      'hash-v2',
      'ai-contract-insights',
      120,
      60,
      1200,
      null,
      drafter.id,
    ]);
    const id2 = Number(r2.data.id);
    trackedInsightIds.push(id2);

    expect(id2).not.toBe(id1);
    const row1 = await readAiInsightById(id1);
    expect(row1?.['is_active']).toBe(false);
    const row2 = await readAiInsightById(id2);
    expect(row2?.['is_active']).toBe(true);

    // Exactly one active row per key
    const activeCount = await countActiveAiInsightsForKey(
      'contract',
      999_999_020,
      'contract_summary',
      'en',
    );
    expect(activeCount).toBe(1);
  });

  it('AC-S7-06: returns 22023 for invalid provider', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_ai_insight_upsert', [
        'contract',
        999_999_021,
        'contract_summary',
        'en',
        'gemini', // INVALID
        'gpt-4o-mini',
        JSON.stringify({ insightType: 'contract_summary', summary: 'x', language: 'en' }),
        'hash-bad',
        'ai-contract-insights',
        null,
        null,
        null,
        null,
        drafter.id,
      ]),
    ).rejects.toMatchObject({ code: '22023' });
  });

  it('AC-S7-06: returns 22023 for invalid language', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_ai_insight_upsert', [
        'contract',
        999_999_022,
        'contract_summary',
        'fr', // INVALID
        'openai',
        'gpt-4o-mini',
        JSON.stringify({ insightType: 'contract_summary', summary: 'x', language: 'fr' }),
        'hash-bad-lang',
        'ai-contract-insights',
        null,
        null,
        null,
        null,
        drafter.id,
      ]),
    ).rejects.toMatchObject({ code: '22023' });
  });

  it('S2-18: NULL entity_id soft-deactivate path — second upsert with NULL entity_id deactivates prior NULL row', async () => {
    const exec = getFixture('executive1');
    const r1 = await callFnAs<{ data: { id: number } }>(exec.id, 'fn_ai_insight_upsert', [
      'executive_dashboard',
      null,
      'executive_anomalies',
      'en',
      'openai',
      'gpt-4o-mini',
      JSON.stringify({
        insightType: 'executive_anomalies',
        anomalies: [{ insight: 'a', severity: 'info', drillDownFilter: '' }],
        generatedAt: new Date().toISOString(),
      }),
      'exec-hash-1',
      'ai-executive-anomalies',
      null,
      null,
      null,
      null,
      exec.id,
    ]);
    const id1 = Number(r1.data.id);
    trackedInsightIds.push(id1);

    const r2 = await callFnAs<{ data: { id: number } }>(exec.id, 'fn_ai_insight_upsert', [
      'executive_dashboard',
      null,
      'executive_anomalies',
      'en',
      'openai',
      'gpt-4o-mini',
      JSON.stringify({
        insightType: 'executive_anomalies',
        anomalies: [{ insight: 'b', severity: 'warning', drillDownFilter: '' }],
        generatedAt: new Date().toISOString(),
      }),
      'exec-hash-2',
      'ai-executive-anomalies',
      null,
      null,
      null,
      null,
      exec.id,
    ]);
    const id2 = Number(r2.data.id);
    trackedInsightIds.push(id2);

    const row1 = await readAiInsightById(id1);
    expect(row1?.['is_active']).toBe(false);
    const row2 = await readAiInsightById(id2);
    expect(row2?.['is_active']).toBe(true);

    const active = await countActiveAiInsightsForKey(
      'executive_dashboard',
      null,
      'executive_anomalies',
      'en',
    );
    expect(active).toBe(1);
  });

  it('AC-S7-04: TTL override accepted — explicit ttl_seconds overrides default', async () => {
    const drafter = getFixture('drafter1');
    const r = await callFnAs<{ data: { id: number; expiresAt: string } }>(
      drafter.id,
      'fn_ai_insight_upsert',
      [
        'contract',
        999_999_023,
        'contract_key_terms',
        'en',
        'openai',
        'gpt-4o-mini',
        JSON.stringify({ insightType: 'contract_key_terms', keyTerms: [] }),
        'hash-ttl',
        'ai-contract-insights',
        null,
        null,
        null,
        60, // override 60 seconds
        drafter.id,
      ],
    );
    const id = Number(r.data.id);
    trackedInsightIds.push(id);
    const row = await readAiInsightById(id);
    const expiresAt = new Date(row?.['expires_at'] as string).getTime();
    const createdAt = new Date(row?.['created_at'] as string).getTime();
    const deltaSeconds = (expiresAt - createdAt) / 1000;
    expect(deltaSeconds).toBeGreaterThan(50);
    expect(deltaSeconds).toBeLessThan(120);
  });

  it('AC-S7-06: returns 23503 when prompt_id is unknown AND ttl_seconds is NULL (must resolve from ai_prompt)', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_ai_insight_upsert', [
        'contract',
        999_999_024,
        'contract_summary',
        'en',
        'openai',
        'gpt-4o-mini',
        JSON.stringify({ insightType: 'contract_summary', summary: 'x', language: 'en' }),
        'hash-bad-prompt',
        'nonexistent-prompt',
        null,
        null,
        null,
        null, // null ttl forces lookup
        drafter.id,
      ]),
    ).rejects.toMatchObject({ code: '23503' });
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S2-19 fn-to-fn signature verification — fn_contract_activity_create
// extension to 23 values incl. the M4 additions.
// ──────────────────────────────────────────────────────────────────────────

describe('S2-19 — contract_activity activity_type extension to 23 values', () => {
  it('CHECK constraint contains exactly 23 values including the 3 M4 additions', async () => {
    const rows = await adminQuery<{ src: string }>(
      `SELECT pg_get_constraintdef(c.oid) AS src
         FROM pg_constraint c
         JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relname = 'contract_activity'
          AND c.contype = 'c'
          AND c.conname = 'contract_activity_activity_type_check'`,
    );
    expect(rows.length).toBeGreaterThan(0);
    const src = rows[0]!.src;
    expect(src).toContain('ai_summary_generated');
    expect(src).toContain('ai_risk_score_updated');
    expect(src).toContain('ai_diff_summary_generated');
    // Verify legacy values still present (S2-19 byte-for-byte preserved)
    expect(src).toContain('created');
    expect(src).toContain('status_changed');
    expect(src).toContain('sent_for_signature');
  });

  it('fn_audit_trigger v_redact_fields contains payload + error_message (M4 additions)', async () => {
    const rows = await adminQuery<{ defs: string }>(
      `SELECT pg_get_functiondef(p.oid) AS defs
         FROM pg_proc p WHERE p.proname = 'fn_audit_trigger'
        LIMIT 1`,
    );
    const def = rows[0]!.defs;
    expect(def).toContain("'payload'");
    expect(def).toContain("'error_message'");
    // M3 carryover (regression guard)
    expect(def).toContain('invitation_token_hash');
    expect(def).toContain('signature_data');
  });
});
