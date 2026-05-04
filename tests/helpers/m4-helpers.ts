/**
 * Shared helpers for M4 (AI Features) tests.
 *
 * Provides:
 *   - seedAiPrompt — direct admin upsert of an ai_prompt row used by isolated
 *     tests (most tests reuse the seeded 6 production prompts).
 *   - seedAiInsight — direct INSERT of an ai_insight row (BYPASSRLS) for cache
 *     hit / miss assertions. Supports entity_id=NULL (executive_dashboard).
 *   - seedAiRequestLog — direct INSERT of ai_request_log rows for rate-limit /
 *     cost report / list filter tests.
 *   - cleanupAiArtifacts — afterAll bulk delete of all rows we touched.
 *   - readAiInsightById / readAiRequestLogById / readAiPromptById — bypass-RLS
 *     reads for assertions.
 *   - countAiInsightsByKey / countAiRequestLogsByActor — quick aggregation.
 *   - signSignedPdfToken — mint a signed-PDF JWT for S5 tests (uses
 *     SIGNED_PDF_TOKEN_SECRET if set; otherwise tests skip).
 *
 * Reuses M1c fixture user pool (drafter1, executive1, legal_counsel1, etc.)
 * + M2 callFnAs primitive.
 */
import jwt from 'jsonwebtoken';
import { adminPool, adminQuery } from './m1a-helpers';

// ---------------------------------------------------------------------------
// Identification — every M4 helper-emitted row carries a tag so the broad
// cleanup helper can hard-delete deterministically without nuking data
// belonging to parallel test files.
// ---------------------------------------------------------------------------
export const M4_TEST_TAG_PREFIX = 'm4test:' as const;

export const tagFor = (suite: string): string =>
  `${M4_TEST_TAG_PREFIX}${suite}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;

// ---------------------------------------------------------------------------
// ai_prompt seed/cleanup
// ---------------------------------------------------------------------------

export interface SeedAiPromptInput {
  promptId: string;
  descriptionEn?: string;
  descriptionAr?: string;
  defaultModel?: string;
  defaultTemperature?: number;
  defaultMaxTokens?: number;
  defaultTtlSeconds?: number;
  supportsStreaming?: boolean;
  supportsToolCall?: boolean;
  publicEndpoint?: boolean;
  promptFilePath?: string;
  rateLimitPerUserPerHour?: number;
  rateLimitPerUserPerDay?: number;
  isActive?: boolean;
}

/**
 * Idempotent INSERT/UPDATE of an ai_prompt row by prompt_id.
 * Uses ON CONFLICT (prompt_id) DO UPDATE so re-runs on the test branch are safe.
 */
export const seedAiPrompt = async (input: SeedAiPromptInput): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      `INSERT INTO ai_prompt
         (prompt_id, description_en, description_ar, default_model,
          default_temperature, default_max_tokens, default_ttl_seconds,
          supports_streaming, supports_tool_call, public_endpoint,
          prompt_file_path, rate_limit_per_user_per_hour,
          rate_limit_per_user_per_day, is_active, created_by, updated_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, 1, 1)
       ON CONFLICT (prompt_id) DO UPDATE
         SET description_en             = EXCLUDED.description_en,
             description_ar             = EXCLUDED.description_ar,
             default_model              = EXCLUDED.default_model,
             default_temperature        = EXCLUDED.default_temperature,
             default_max_tokens         = EXCLUDED.default_max_tokens,
             default_ttl_seconds        = EXCLUDED.default_ttl_seconds,
             supports_streaming         = EXCLUDED.supports_streaming,
             supports_tool_call         = EXCLUDED.supports_tool_call,
             public_endpoint            = EXCLUDED.public_endpoint,
             prompt_file_path           = EXCLUDED.prompt_file_path,
             rate_limit_per_user_per_hour = EXCLUDED.rate_limit_per_user_per_hour,
             rate_limit_per_user_per_day  = EXCLUDED.rate_limit_per_user_per_day,
             is_active                  = EXCLUDED.is_active,
             updated_by                 = 1,
             updated_at                 = CURRENT_TIMESTAMP`,
      [
        input.promptId,
        input.descriptionEn ?? `m4-helper-prompt:${input.promptId}`,
        input.descriptionAr ?? `m4-helper-prompt-ar:${input.promptId}`,
        input.defaultModel ?? 'gpt-4o-mini',
        input.defaultTemperature ?? 0.4,
        input.defaultMaxTokens ?? 1000,
        input.defaultTtlSeconds ?? 3600,
        input.supportsStreaming ?? false,
        input.supportsToolCall ?? false,
        input.publicEndpoint ?? false,
        input.promptFilePath ?? `prompts/${input.promptId}.txt`,
        input.rateLimitPerUserPerHour ?? 60,
        input.rateLimitPerUserPerDay ?? 1000,
        input.isActive ?? true,
      ],
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
 * Hard-delete an ai_prompt by prompt_id. Used to clean up ad-hoc test prompts
 * that aren't part of the canonical 6-row seed.
 */
export const deleteAiPromptById = async (promptId: string): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    // Children first (ai_request_log FK on prompt_id is RESTRICT — but in
    // tests we seed minimal rows attached to ad-hoc prompts; cascade them).
    await client.query('DELETE FROM ai_request_log WHERE prompt_id = $1', [promptId]);
    await client.query('DELETE FROM ai_insight    WHERE prompt_id = $1', [promptId]);
    await client.query('DELETE FROM ai_prompt     WHERE prompt_id = $1', [promptId]);
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

// ---------------------------------------------------------------------------
// ai_insight seed
// ---------------------------------------------------------------------------

export interface SeedAiInsightInput {
  entityType: string;
  entityId: number | null;
  insightType: string;
  language: 'en' | 'ar' | 'bilingual';
  promptId: string;
  provider?: 'openai' | 'anthropic';
  modelUsed?: string;
  payload?: Record<string, unknown>;
  payloadHash?: string;
  tokensInput?: number | null;
  tokensOutput?: number | null;
  costUsdMicros?: number | null;
  ttlSeconds?: number;
  /** override expires_at directly (e.g. backdate to test cron eviction). */
  expiresAt?: Date | null;
  isActive?: boolean;
  actorUserId: number;
}

/**
 * Direct INSERT of an ai_insight row. Bypasses fn_ai_insight_upsert so tests
 * can stage backdated / mass-expired rows without going through the
 * SELECT-FOR-UPDATE atomic upsert path.
 *
 * Returns the inserted id.
 */
export const seedAiInsight = async (input: SeedAiInsightInput): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const expiresAt = input.expiresAt
      ? input.expiresAt
      : new Date(Date.now() + (input.ttlSeconds ?? 3600) * 1000);
    const r = await client.query<{ id: number | string }>(
      `INSERT INTO ai_insight
         (entity_type, entity_id, insight_type, language,
          prompt_id, provider, model_used, payload, payload_hash,
          tokens_input, tokens_output, cost_usd_micros,
          expires_at, created_by, updated_by, is_active)
         VALUES ($1, $2, $3, $4,
                 $5, $6, $7, $8::jsonb, $9,
                 $10, $11, $12,
                 $13, $14, $14, $15)
         RETURNING id`,
      [
        input.entityType,
        input.entityId,
        input.insightType,
        input.language,
        input.promptId,
        input.provider ?? 'openai',
        input.modelUsed ?? 'gpt-4o-mini',
        JSON.stringify(input.payload ?? { insightType: input.insightType, marker: M4_TEST_TAG_PREFIX }),
        input.payloadHash ?? `hash-${Date.now()}-${Math.random()}`,
        input.tokensInput ?? null,
        input.tokensOutput ?? null,
        input.costUsdMicros ?? null,
        expiresAt,
        input.actorUserId,
        input.isActive ?? true,
      ],
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

// ---------------------------------------------------------------------------
// ai_request_log seed
// ---------------------------------------------------------------------------

export interface SeedAiRequestLogInput {
  promptId: string;
  actorUserId: number | null;
  outcome?: 'success' | 'error' | 'timeout' | 'rate_limited' | 'cancelled';
  cacheHit?: boolean;
  language?: 'en' | 'ar' | 'bilingual';
  provider?: 'openai' | 'anthropic';
  modelUsed?: string;
  tokensInput?: number | null;
  tokensOutput?: number | null;
  costUsdMicros?: number | null;
  latencyMs?: number | null;
  mode?: string | null;
  entityType?: string | null;
  entityId?: number | null;
  errorClass?: string | null;
  errorMessage?: string | null;
  /** Optional backdate. */
  createdAt?: Date;
  streamMode?: boolean;
}

/**
 * Direct INSERT of an ai_request_log row. The append-only deny-update trigger
 * fires on UPDATE only — DELETE remains permissible from the BYPASSRLS pool.
 *
 * Returns the inserted id.
 */
export const seedAiRequestLog = async (
  input: SeedAiRequestLogInput,
): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const created = input.createdAt ?? new Date();
    const r = await client.query<{ id: number | string }>(
      `INSERT INTO ai_request_log
         (request_id, prompt_id, mode, actor_user_id,
          entity_type, entity_id, language, provider, model_used,
          tokens_input, tokens_output, cost_usd_micros, latency_ms,
          cache_hit, stream_mode, outcome, error_class, error_message,
          created_at)
         VALUES (gen_random_uuid(), $1, $2, $3,
                 $4, $5, $6, $7, $8,
                 $9, $10, $11, $12,
                 $13, $14, $15, $16, $17,
                 $18)
         RETURNING id`,
      [
        input.promptId,
        input.mode ?? null,
        input.actorUserId,
        input.entityType ?? null,
        input.entityId ?? null,
        input.language ?? 'en',
        input.provider ?? 'openai',
        input.modelUsed ?? 'gpt-4o-mini',
        input.tokensInput ?? 100,
        input.tokensOutput ?? 50,
        input.costUsdMicros ?? 1000,
        input.latencyMs ?? 250,
        input.cacheHit ?? false,
        input.streamMode ?? false,
        input.outcome ?? 'success',
        input.errorClass ?? null,
        input.errorMessage ?? null,
        created,
      ],
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

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

export const readAiInsightById = async (
  id: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, entity_type, entity_id, insight_type, language,
            prompt_id, provider, model_used, payload, payload_hash,
            tokens_input, tokens_output, cost_usd_micros,
            expires_at, created_at, updated_at,
            created_by, updated_by, is_active
       FROM ai_insight WHERE id = $1`,
    [id],
  );
  return rows[0] ?? null;
};

export const readAiRequestLogById = async (
  id: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, request_id, prompt_id, mode, actor_user_id,
            entity_type, entity_id, language, provider, model_used,
            tokens_input, tokens_output, cost_usd_micros, latency_ms,
            cache_hit, stream_mode, outcome, error_class, error_message,
            created_at, is_active
       FROM ai_request_log WHERE id = $1`,
    [id],
  );
  return rows[0] ?? null;
};

export const readAiPromptById = async (
  promptId: string,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT prompt_id, description_en, description_ar, default_model,
            default_temperature, default_max_tokens, default_ttl_seconds,
            supports_streaming, supports_tool_call, public_endpoint,
            prompt_file_path, rate_limit_per_user_per_hour,
            rate_limit_per_user_per_day, is_active
       FROM ai_prompt WHERE prompt_id = $1`,
    [promptId],
  );
  return rows[0] ?? null;
};

export const countActiveAiInsightsForKey = async (
  entityType: string,
  entityId: number | null,
  insightType: string,
  language: string,
): Promise<number> => {
  const rows = await adminQuery<{ count: string }>(
    `SELECT COUNT(*)::text AS count FROM ai_insight
       WHERE entity_type = $1
         AND entity_id IS NOT DISTINCT FROM $2
         AND insight_type = $3
         AND language = $4
         AND is_active = TRUE`,
    [entityType, entityId, insightType, language],
  );
  return Number(rows[0]?.count ?? 0);
};

export const countAiRequestLogsForActorPrompt = async (
  actorUserId: number,
  promptId: string,
): Promise<number> => {
  const rows = await adminQuery<{ count: string }>(
    `SELECT COUNT(*)::text AS count FROM ai_request_log
       WHERE actor_user_id = $1 AND prompt_id = $2`,
    [actorUserId, promptId],
  );
  return Number(rows[0]?.count ?? 0);
};

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

/**
 * Hard-delete an arbitrary list of ai_insight + ai_request_log ids.
 */
export const cleanupAiArtifacts = async (params: {
  insightIds?: number[];
  requestLogIds?: number[];
  promptIds?: string[];
  /**
   * Also delete contract_activity rows of M4 type for the given contracts so
   * cross-test residue does not pollute fn_contract_activity_create whitelist
   * checks.
   */
  contractIds?: number[];
}): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    if (params.requestLogIds && params.requestLogIds.length > 0) {
      await client.query('DELETE FROM ai_request_log WHERE id = ANY($1::BIGINT[])', [
        params.requestLogIds,
      ]);
    }
    if (params.insightIds && params.insightIds.length > 0) {
      await client.query('DELETE FROM ai_insight WHERE id = ANY($1::BIGINT[])', [
        params.insightIds,
      ]);
    }
    if (params.promptIds && params.promptIds.length > 0) {
      await client.query('DELETE FROM ai_request_log WHERE prompt_id = ANY($1)', [
        params.promptIds,
      ]);
      await client.query('DELETE FROM ai_insight WHERE prompt_id = ANY($1)', [
        params.promptIds,
      ]);
      await client.query('DELETE FROM ai_prompt WHERE prompt_id = ANY($1)', [
        params.promptIds,
      ]);
    }
    if (params.contractIds && params.contractIds.length > 0) {
      await client.query(
        `DELETE FROM contract_activity
          WHERE contract_id = ANY($1::BIGINT[])
            AND activity_type IN ('ai_summary_generated','ai_risk_score_updated','ai_diff_summary_generated')`,
        [params.contractIds],
      );
    }
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

// ---------------------------------------------------------------------------
// Signed-PDF token helper (S5)
// ---------------------------------------------------------------------------

/**
 * Mint an HMAC-signed PDF token for the S5 endpoint integration test.
 * Returns null when SIGNED_PDF_TOKEN_SECRET is not set in env — caller should
 * skip the test in that case.
 */
export interface SignedPdfTokenOptions {
  sub?: string;
  expiresInSeconds?: number;
  issuer?: string;
  audience?: string;
  /** Override secret (e.g., to mint an INVALID token signed with a different key). */
  secretOverride?: string;
  /** Force expired token (sets exp in the past). */
  forceExpired?: boolean;
}

export const signSignedPdfToken = (opts: SignedPdfTokenOptions = {}): string | null => {
  const secret = opts.secretOverride ?? process.env.SIGNED_PDF_TOKEN_SECRET;
  if (!secret) return null;
  const issuer = opts.issuer ?? process.env.SIGNED_PDF_TOKEN_ISSUER ?? 'musanad-contracts-pdf';
  const audience = opts.audience ?? process.env.SIGNED_PDF_TOKEN_AUDIENCE ?? 'regulatory-impact-pdf';
  const now = Math.floor(Date.now() / 1000);
  const exp = opts.forceExpired
    ? now - 60
    : now + (opts.expiresInSeconds ?? 3600);
  const payload: Record<string, unknown> = {
    sub: opts.sub ?? `m4-test-${Date.now()}`,
    aud: audience,
    iss: issuer,
    iat: now,
    exp,
    jti: `test-${Math.random().toString(36).slice(2)}`,
  };
  return jwt.sign(payload, secret, { algorithm: 'HS256', noTimestamp: true });
};

/**
 * Probe that the SIGNED_PDF_TOKEN_SECRET env var is configured. Tests that
 * exercise the S5 happy path skip when this returns false.
 */
export const isSignedPdfTokenConfigured = (): boolean =>
  typeof process.env.SIGNED_PDF_TOKEN_SECRET === 'string' &&
  process.env.SIGNED_PDF_TOKEN_SECRET.length > 0;
