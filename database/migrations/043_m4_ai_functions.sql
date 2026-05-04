-- ============================================================================
-- 043_m4_ai_functions.sql
-- ============================================================================
-- Module:    M4 (AI Features)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   042 (ai_prompt, ai_insight, ai_request_log tables, RLS, triggers);
--            040 (extended fn_contract_activity_create whitelist);
--            M0 (fn_current_user_has_permission, fn_user_get_by_id);
--            M1a (fn_contract_activity_create call sites — 6-arg signature).
-- ----------------------------------------------------------------------------
-- 12 new fn_ + GRANT EXECUTE matrix:
--   neondb_owner only (DEFINER writes / system / pre-flight gates):
--     fn_ai_insight_get_cached
--     fn_ai_insight_upsert
--     fn_ai_insight_evict_expired           (system / cron)
--     fn_ai_request_log_create
--     fn_ai_request_log_check_rate_limit
--     fn_contract_ai_summary_persist        (DEFINER carve-out)
--     fn_contract_version_diff_summary_persist (DEFINER carve-out)
--   authenticated (RLS narrows):
--     fn_ai_prompt_get  (INVOKER)
--     fn_ai_prompt_list (INVOKER)
--     fn_ai_insight_list (INVOKER)
--     fn_ai_request_log_list (INVOKER)
--     fn_ai_request_log_cost_report (INVOKER)
--
-- S2-19 fn-to-fn signature verification:
--   fn_contract_activity_create — 6-arg (BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) RETURNS JSONB
--   fn_current_user_has_permission — 1-arg (TEXT) RETURNS BOOLEAN (DB-IMPL-I-3 lesson)
--
-- S2-17 concurrency primitives:
--   fn_ai_insight_upsert — SELECT FOR UPDATE on prior active row before INSERT
--   fn_ai_insight_evict_expired — FOR UPDATE OF SKIP LOCKED
--   fn_contract_ai_summary_persist — SELECT FOR UPDATE on contract row
--   fn_contract_version_diff_summary_persist — SELECT FOR UPDATE on contract_version row
--
-- S2-18 NULL-safe equality:
--   fn_ai_insight_get_cached + fn_ai_insight_upsert use IS NOT DISTINCT FROM on entity_id
--
-- S2-20 system-event actor sentinel:
--   fn_ai_insight_evict_expired is SECURITY DEFINER + REVOKE FROM PUBLIC
--   + GRANT EXECUTE TO neondb_owner only. Cron driver MUST SET app.current_user_id='0'.
--
-- ALL fn_ JSONB keys are camelCase. Sensitive fields (payload, error_message,
-- ai_prompt_payload) NEVER appear in RAISE EXCEPTION messages.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. fn_ai_insight_get_cached (DEFINER read; cache lookup)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_insight_get_cached(
  p_entity_type   TEXT,
  p_entity_id     BIGINT,
  p_insight_type  TEXT,
  p_language      TEXT,
  p_payload_hash  TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row ai_insight%ROWTYPE;
BEGIN
  SELECT *
    INTO v_row
    FROM ai_insight
    WHERE entity_type = p_entity_type
      AND entity_id IS NOT DISTINCT FROM p_entity_id    -- S2-18 NULL-safe
      AND insight_type = p_insight_type
      AND language = p_language
      AND (p_payload_hash IS NULL OR payload_hash = p_payload_hash)
      AND is_active = TRUE
      AND expires_at > CURRENT_TIMESTAMP                 -- expired => cache miss
    ORDER BY created_at DESC
    LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id',             v_row.id,
    'entityType',     v_row.entity_type,
    'entityId',       v_row.entity_id,
    'insightType',    v_row.insight_type,
    'language',       v_row.language,
    'promptId',       v_row.prompt_id,
    'provider',       v_row.provider,
    'modelUsed',      v_row.model_used,
    'payload',        v_row.payload,
    'payloadHash',    v_row.payload_hash,
    'tokensInput',    v_row.tokens_input,
    'tokensOutput',   v_row.tokens_output,
    'costUsdMicros',  v_row.cost_usd_micros,
    'expiresAt',      v_row.expires_at,
    'createdAt',      v_row.created_at
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_insight_get_cached(TEXT, BIGINT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_insight_get_cached(TEXT, BIGINT, TEXT, TEXT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_insight_get_cached(TEXT, BIGINT, TEXT, TEXT, TEXT) IS
  'M4 (043) — DEFINER cache lookup. NULL-safe equality on entity_id (S2-18). Returns NULL on miss / expired.';

-- ============================================================================
-- 2. fn_ai_insight_upsert (DEFINER write; atomic soft-deactivate + INSERT)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_insight_upsert(
  p_entity_type     TEXT,
  p_entity_id       BIGINT,
  p_insight_type    TEXT,
  p_language        TEXT,
  p_provider        TEXT,
  p_model_used      TEXT,
  p_payload         JSONB,
  p_payload_hash    TEXT,
  p_prompt_id       TEXT,
  p_tokens_input    INTEGER,
  p_tokens_output   INTEGER,
  p_cost_usd_micros BIGINT,
  p_ttl_seconds     INTEGER,
  p_actor_user_id   BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_resolved_ttl  INTEGER;
  v_default_ttl   INTEGER;
  v_expires_at    TIMESTAMPTZ;
  v_prior_id      BIGINT;
  v_new_id        BIGINT;
BEGIN
  -- 1. Validate enums.
  IF p_provider NOT IN ('openai','anthropic') THEN
    RAISE EXCEPTION 'fn_ai_insight_upsert: %', 'provider:Invalid provider'
      USING ERRCODE = '22023';
  END IF;
  IF p_language NOT IN ('en','ar','bilingual') THEN
    RAISE EXCEPTION 'fn_ai_insight_upsert: %', 'language:Invalid language'
      USING ERRCODE = '22023';
  END IF;

  -- 2. Resolve TTL.
  IF p_ttl_seconds IS NULL THEN
    SELECT default_ttl_seconds INTO v_default_ttl
      FROM ai_prompt
      WHERE prompt_id = p_prompt_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_ai_insight_upsert: %', 'promptId:Prompt not found or inactive'
        USING ERRCODE = '23503';
    END IF;
    v_resolved_ttl := v_default_ttl;
  ELSE
    v_resolved_ttl := p_ttl_seconds;
  END IF;

  v_expires_at := CURRENT_TIMESTAMP + (v_resolved_ttl || ' seconds')::INTERVAL;

  -- 3. SELECT FOR UPDATE prior active row (S2-17 atomic upsert; S2-18 NULL-safe equality).
  SELECT id INTO v_prior_id
    FROM ai_insight
    WHERE entity_type = p_entity_type
      AND entity_id IS NOT DISTINCT FROM p_entity_id
      AND insight_type = p_insight_type
      AND language = p_language
      AND is_active = TRUE
    FOR UPDATE;

  -- 4. Soft-deactivate prior row.
  IF v_prior_id IS NOT NULL THEN
    UPDATE ai_insight
      SET is_active = FALSE,
          updated_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_user_id
      WHERE id = v_prior_id;
  END IF;

  -- 5. INSERT new row.
  INSERT INTO ai_insight (
    entity_type, entity_id, insight_type, language,
    payload_hash, prompt_id, provider, model_used,
    payload, tokens_input, tokens_output, cost_usd_micros,
    expires_at, created_by, updated_by, is_active
  ) VALUES (
    p_entity_type, p_entity_id, p_insight_type, p_language,
    p_payload_hash, p_prompt_id, p_provider, p_model_used,
    p_payload, p_tokens_input, p_tokens_output, p_cost_usd_micros,
    v_expires_at, p_actor_user_id, p_actor_user_id, TRUE
  ) RETURNING id INTO v_new_id;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'id',         v_new_id,
      'expiresAt',  v_expires_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_insight_upsert(TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_insight_upsert(TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_insight_upsert(TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BIGINT) IS
  'M4 (043) — DEFINER atomic soft-deactivate + INSERT cache write. SELECT FOR UPDATE (S2-17) on prior active row keyed by NULL-safe equality (S2-18). Returns { id, expiresAt }.';

-- ============================================================================
-- 3. fn_ai_insight_evict_expired (DEFINER, system-cron only)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_insight_evict_expired(
  p_batch_size INTEGER DEFAULT 500
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_now      TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_batch    INTEGER;
  v_evicted  INTEGER := 0;
  v_row      RECORD;
BEGIN
  v_batch := COALESCE(NULLIF(p_batch_size, 0), 500);
  IF v_batch < 1 THEN
    v_batch := 500;
  END IF;

  FOR v_row IN
    SELECT id
      FROM ai_insight
      WHERE is_active = TRUE
        AND expires_at IS NOT NULL
        AND expires_at <= v_now
      ORDER BY expires_at ASC
      LIMIT v_batch
      FOR UPDATE SKIP LOCKED                              -- S2-17 cron-safe
  LOOP
    UPDATE ai_insight
      SET is_active = FALSE,
          updated_at = v_now
      WHERE id = v_row.id;
    v_evicted := v_evicted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'data', jsonb_build_object('evictedCount', v_evicted)
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_insight_evict_expired(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_insight_evict_expired(INTEGER) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_insight_evict_expired(INTEGER) IS
  'M4 (043) — DEFINER, system-cron only (REVOKE FROM PUBLIC; GRANT TO neondb_owner). Mirrors M2 fn_approval_escalate / M3 fn_signature_invitation_expire_due. SKIP LOCKED batched. Cron driver MUST SET app.current_user_id=''0'' (S2-20). Soft-delete only — NEVER hard-DELETEs.';

-- ============================================================================
-- 4. fn_ai_request_log_create (DEFINER append-only insert)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_request_log_create(
  p_request_id      UUID,
  p_prompt_id       TEXT,
  p_mode            TEXT,
  p_actor_user_id   BIGINT,
  p_entity_type     TEXT,
  p_entity_id       BIGINT,
  p_language        TEXT,
  p_provider        TEXT,
  p_model_used      TEXT,
  p_tokens_input    INTEGER,
  p_tokens_output   INTEGER,
  p_cost_usd_micros BIGINT,
  p_latency_ms      INTEGER,
  p_cache_hit       BOOLEAN,
  p_stream_mode     BOOLEAN,
  p_outcome         TEXT,
  p_error_class     TEXT,
  p_error_message   TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  -- Validate enums (the table CHECK is the second line of defence).
  IF p_outcome NOT IN ('success','error','timeout','rate_limited','cancelled') THEN
    RAISE EXCEPTION 'fn_ai_request_log_create: %', 'outcome:Invalid outcome'
      USING ERRCODE = '22023';
  END IF;
  IF p_provider NOT IN ('openai','anthropic') THEN
    RAISE EXCEPTION 'fn_ai_request_log_create: %', 'provider:Invalid provider'
      USING ERRCODE = '22023';
  END IF;
  IF p_language NOT IN ('en','ar','bilingual') THEN
    RAISE EXCEPTION 'fn_ai_request_log_create: %', 'language:Invalid language'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO ai_request_log (
    request_id, prompt_id, mode, actor_user_id,
    entity_type, entity_id, language, provider, model_used,
    tokens_input, tokens_output, cost_usd_micros, latency_ms,
    cache_hit, stream_mode, outcome, error_class, error_message
  ) VALUES (
    p_request_id, p_prompt_id, p_mode, p_actor_user_id,
    p_entity_type, p_entity_id, p_language, p_provider, p_model_used,
    p_tokens_input, p_tokens_output, p_cost_usd_micros, p_latency_ms,
    p_cache_hit, p_stream_mode, p_outcome, p_error_class, p_error_message
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'id',        v_id,
      'requestId', p_request_id
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_request_log_create(UUID, TEXT, TEXT, BIGINT, TEXT, BIGINT, TEXT, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BOOLEAN, BOOLEAN, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_request_log_create(UUID, TEXT, TEXT, BIGINT, TEXT, BIGINT, TEXT, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BOOLEAN, BOOLEAN, TEXT, TEXT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_request_log_create(UUID, TEXT, TEXT, BIGINT, TEXT, BIGINT, TEXT, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BOOLEAN, BOOLEAN, TEXT, TEXT, TEXT) IS
  'M4 (043) — DEFINER append-only insert. ai_prompt_payload NEVER a parameter (DN-11 / defence-in-depth). p_error_message is pre-redacted at controller (Pino) before fn call.';

-- ============================================================================
-- 5. fn_ai_request_log_check_rate_limit (DEFINER pre-flight rate gate)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_request_log_check_rate_limit(
  p_actor_user_id BIGINT,
  p_prompt_id     TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hourly_limit  INTEGER;
  v_daily_limit   INTEGER;
  v_count_hour    INTEGER;
  v_count_day     INTEGER;
  v_allowed       BOOLEAN;
  v_retry_after   INTEGER := 0;
  v_oldest_at     TIMESTAMPTZ;
  v_window_start  TIMESTAMPTZ;
BEGIN
  -- 1. Resolve prompt limits.
  SELECT rate_limit_per_user_per_hour, rate_limit_per_user_per_day
    INTO v_hourly_limit, v_daily_limit
    FROM ai_prompt
    WHERE prompt_id = p_prompt_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_ai_request_log_check_rate_limit: %', 'promptId:Prompt not found or inactive'
      USING ERRCODE = '23503';
  END IF;

  -- 2. Count attempts in last hour (success+error+cache_hit count; rate_limited
  --    rows themselves do NOT count; timeout/cancelled excluded as caller-aborts).
  SELECT COUNT(*) INTO v_count_hour
    FROM ai_request_log
    WHERE actor_user_id = p_actor_user_id
      AND prompt_id = p_prompt_id
      AND created_at >= CURRENT_TIMESTAMP - INTERVAL '1 hour'
      AND (outcome IN ('success','error') OR cache_hit = TRUE);

  -- 3. Count attempts in last 24h.
  SELECT COUNT(*) INTO v_count_day
    FROM ai_request_log
    WHERE actor_user_id = p_actor_user_id
      AND prompt_id = p_prompt_id
      AND created_at >= CURRENT_TIMESTAMP - INTERVAL '24 hours'
      AND (outcome IN ('success','error') OR cache_hit = TRUE);

  v_allowed := (v_count_hour < v_hourly_limit) AND (v_count_day < v_daily_limit);

  -- 4. retry-after — seconds until oldest counted row in the breaching window
  --    falls off. Choose the binding window.
  IF NOT v_allowed THEN
    IF v_count_hour >= v_hourly_limit THEN
      v_window_start := CURRENT_TIMESTAMP - INTERVAL '1 hour';
      SELECT MIN(created_at) INTO v_oldest_at
        FROM ai_request_log
        WHERE actor_user_id = p_actor_user_id
          AND prompt_id = p_prompt_id
          AND created_at >= v_window_start
          AND (outcome IN ('success','error') OR cache_hit = TRUE);
      IF v_oldest_at IS NOT NULL THEN
        v_retry_after := GREATEST(1, EXTRACT(EPOCH FROM (v_oldest_at + INTERVAL '1 hour' - CURRENT_TIMESTAMP))::INTEGER);
      END IF;
    ELSE
      v_window_start := CURRENT_TIMESTAMP - INTERVAL '24 hours';
      SELECT MIN(created_at) INTO v_oldest_at
        FROM ai_request_log
        WHERE actor_user_id = p_actor_user_id
          AND prompt_id = p_prompt_id
          AND created_at >= v_window_start
          AND (outcome IN ('success','error') OR cache_hit = TRUE);
      IF v_oldest_at IS NOT NULL THEN
        v_retry_after := GREATEST(1, EXTRACT(EPOCH FROM (v_oldest_at + INTERVAL '24 hours' - CURRENT_TIMESTAMP))::INTEGER);
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'allowed',           v_allowed,
      'remainingHour',     GREATEST(0, v_hourly_limit - v_count_hour),
      'remainingDay',      GREATEST(0, v_daily_limit  - v_count_day),
      'retryAfterSeconds', v_retry_after
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_request_log_check_rate_limit(BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_request_log_check_rate_limit(BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_request_log_check_rate_limit(BIGINT, TEXT) IS
  'M4 (043) — DEFINER pre-flight rate gate (NOT GATE/COMMIT). Counts success+error+cache_hit; rate_limited / timeout / cancelled rows excluded. Returns { allowed, remainingHour, remainingDay, retryAfterSeconds }.';

-- ============================================================================
-- 6. fn_ai_prompt_get (INVOKER read)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_prompt_get(p_prompt_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row ai_prompt%ROWTYPE;
BEGIN
  SELECT * INTO v_row
    FROM ai_prompt
    WHERE prompt_id = p_prompt_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'promptId',                v_row.prompt_id,
    'descriptionEn',           v_row.description_en,
    'descriptionAr',           v_row.description_ar,
    'defaultModel',            v_row.default_model,
    'defaultTemperature',      v_row.default_temperature,
    'defaultMaxTokens',        v_row.default_max_tokens,
    'defaultTtlSeconds',       v_row.default_ttl_seconds,
    'supportsStreaming',       v_row.supports_streaming,
    'supportsToolCall',        v_row.supports_tool_call,
    'publicEndpoint',          v_row.public_endpoint,
    'promptFilePath',          v_row.prompt_file_path,
    'rateLimitPerUserPerHour', v_row.rate_limit_per_user_per_hour,
    'rateLimitPerUserPerDay',  v_row.rate_limit_per_user_per_day,
    'isActive',                v_row.is_active
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_prompt_get(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_prompt_get(TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_prompt_get(TEXT) IS
  'M4 (043) — INVOKER read. Returns ai_prompt row JSONB or NULL on miss.';

-- ============================================================================
-- 7. fn_ai_prompt_list (INVOKER read; paginated)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_prompt_list(
  p_include_inactive BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total INTEGER;
  v_data  JSONB;
BEGIN
  SELECT COUNT(*) INTO v_total
    FROM ai_prompt
    WHERE (p_include_inactive OR is_active = TRUE);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'promptId',                p.prompt_id,
      'descriptionEn',           p.description_en,
      'descriptionAr',           p.description_ar,
      'defaultModel',            p.default_model,
      'defaultTemperature',      p.default_temperature,
      'defaultMaxTokens',        p.default_max_tokens,
      'defaultTtlSeconds',       p.default_ttl_seconds,
      'supportsStreaming',       p.supports_streaming,
      'supportsToolCall',        p.supports_tool_call,
      'publicEndpoint',          p.public_endpoint,
      'promptFilePath',          p.prompt_file_path,
      'rateLimitPerUserPerHour', p.rate_limit_per_user_per_hour,
      'rateLimitPerUserPerDay',  p.rate_limit_per_user_per_day,
      'isActive',                p.is_active
    ) ORDER BY p.prompt_id ASC
  ), '[]'::jsonb) INTO v_data
  FROM ai_prompt p
  WHERE (p_include_inactive OR p.is_active = TRUE);

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       1,
      'limit',      50,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE 1 END
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_prompt_list(BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_prompt_list(BOOLEAN) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_prompt_list(BOOLEAN) IS
  'M4 (043) — INVOKER. Returns all (or active) ai_prompt rows. RLS narrows write to admins; reads are broad (config table).';

-- ============================================================================
-- 8. fn_contract_ai_summary_persist (DEFINER carve-out write)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_contract_ai_summary_persist(
  p_contract_id   BIGINT,
  p_actor_user_id BIGINT,
  p_summary_en    TEXT,
  p_summary_ar    TEXT,
  p_risk_score    INTEGER
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old        RECORD;
  v_new_en     TEXT;
  v_new_ar     TEXT;
  v_new_score  INTEGER;
  v_new_at     TIMESTAMPTZ;
  v_allowed    BOOLEAN;
BEGIN
  -- 1. Permission gate — defence-in-depth (S2-19 1-arg form)
  v_allowed := fn_current_user_has_permission('contract.edit')
            OR fn_current_user_has_permission('contract.read.all');
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'fn_contract_ai_summary_persist: %', 'forbidden'
      USING ERRCODE = '42501';
  END IF;

  -- 2. SELECT FOR UPDATE the contract row (S2-17 lock)
  SELECT id, ai_summary_en, ai_summary_ar, ai_risk_score
    INTO v_old
    FROM contract
    WHERE id = p_contract_id AND is_active = TRUE
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_ai_summary_persist: %', 'contractId:Contract not found'
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. Validate risk score range.
  IF p_risk_score IS NOT NULL AND (p_risk_score < 0 OR p_risk_score > 100) THEN
    RAISE EXCEPTION 'fn_contract_ai_summary_persist: %', 'riskScore:Must be between 0 and 100'
      USING ERRCODE = '23514';
  END IF;

  -- 4. UPDATE the reserved columns (M1a 003).
  UPDATE contract
    SET ai_summary_en = COALESCE(p_summary_en, ai_summary_en),
        ai_summary_ar = COALESCE(p_summary_ar, ai_summary_ar),
        ai_risk_score = COALESCE(p_risk_score, ai_risk_score),
        updated_at    = CURRENT_TIMESTAMP,
        updated_by    = p_actor_user_id
    WHERE id = p_contract_id
    RETURNING ai_summary_en, ai_summary_ar, ai_risk_score, updated_at
    INTO v_new_en, v_new_ar, v_new_score, v_new_at;

  -- 5. Emit contract_activity rows (Q5 — 3 fine-grained values).
  IF p_summary_en IS NOT NULL OR p_summary_ar IS NOT NULL THEN
    PERFORM fn_contract_activity_create(
      p_contract_id,
      'ai_summary_generated',
      p_actor_user_id,
      NULL,
      NULL,
      jsonb_build_object('hasEn', p_summary_en IS NOT NULL, 'hasAr', p_summary_ar IS NOT NULL)
    );
  END IF;

  IF p_risk_score IS NOT NULL AND p_risk_score IS DISTINCT FROM v_old.ai_risk_score THEN
    PERFORM fn_contract_activity_create(
      p_contract_id,
      'ai_risk_score_updated',
      p_actor_user_id,
      NULL,
      NULL,
      jsonb_build_object('oldRiskScore', v_old.ai_risk_score, 'newRiskScore', p_risk_score)
    );
  END IF;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'contractId',  p_contract_id,
      'aiSummaryEn', v_new_en,
      'aiSummaryAr', v_new_ar,
      'aiRiskScore', v_new_score,
      'updatedAt',   v_new_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_ai_summary_persist(BIGINT, BIGINT, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_ai_summary_persist(BIGINT, BIGINT, TEXT, TEXT, INTEGER) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_ai_summary_persist(BIGINT, BIGINT, TEXT, TEXT, INTEGER) IS
  'M4 (043) — DEFINER carve-out (caller may not have contract.update). Updates contract.ai_summary_en/_ar/ai_risk_score (M1a 003 reserved cols). Emits ai_summary_generated + ai_risk_score_updated activities. S2-17 SELECT FOR UPDATE; S2-19 6-arg fn_contract_activity_create + 1-arg fn_current_user_has_permission.';

-- ============================================================================
-- 9. fn_contract_version_diff_summary_persist (DEFINER carve-out — append-only table)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_contract_version_diff_summary_persist(
  p_contract_version_id BIGINT,
  p_actor_user_id       BIGINT,
  p_diff_summary        TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row     RECORD;
  v_new_at  TIMESTAMPTZ;
  v_allowed BOOLEAN;
BEGIN
  -- 1. Permission gate (defence-in-depth; controller already validated).
  v_allowed := fn_current_user_has_permission('contract.read.all')
            OR fn_current_user_has_permission('contract.read.department')
            OR fn_current_user_has_permission('contract.read.own')
            OR fn_current_user_has_permission('contract.edit');
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'fn_contract_version_diff_summary_persist: %', 'forbidden'
      USING ERRCODE = '42501';
  END IF;

  -- 2. SELECT FOR UPDATE the version row (S2-17 lock).
  SELECT cv.id, cv.contract_id
    INTO v_row
    FROM contract_version cv
    WHERE cv.id = p_contract_version_id AND cv.is_active = TRUE
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_version_diff_summary_persist: %', 'contractVersionId:Contract version not found'
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. UPDATE diff_summary (M1a-reserved column on otherwise-append-only table).
  --    DEFINER carve-out documented in DN-3.
  UPDATE contract_version
    SET diff_summary = p_diff_summary,
        updated_at   = CURRENT_TIMESTAMP,
        updated_by   = p_actor_user_id
    WHERE id = p_contract_version_id
    RETURNING updated_at INTO v_new_at;

  -- 4. Emit contract_activity (parent contract scope).
  PERFORM fn_contract_activity_create(
    v_row.contract_id,
    'ai_diff_summary_generated',
    p_actor_user_id,
    NULL,
    NULL,
    jsonb_build_object('contractVersionId', p_contract_version_id)
  );

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'contractVersionId', p_contract_version_id,
      'diffSummary',       p_diff_summary,
      'updatedAt',         v_new_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_version_diff_summary_persist(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_version_diff_summary_persist(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_version_diff_summary_persist(BIGINT, BIGINT, TEXT) IS
  'M4 (043) — DEFINER carve-out. contract_version is append-only at table level; this fn is the ONLY allowed UPDATE path on diff_summary column (M1a-reserved). Future modules MUST NOT add additional UPDATE-via-DEFINER carve-outs without explicit invariant review (DN-3).';

-- ============================================================================
-- 10. fn_ai_insight_list (INVOKER paginated list)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_insight_list(
  p_page             INTEGER DEFAULT 1,
  p_limit            INTEGER DEFAULT 20,
  p_entity_type      TEXT    DEFAULT NULL,
  p_insight_type     TEXT    DEFAULT NULL,
  p_language         TEXT    DEFAULT NULL,
  p_provider         TEXT    DEFAULT NULL,
  p_include_expired  BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset  INTEGER;
  v_limit   INTEGER;
  v_total   INTEGER;
  v_data    JSONB;
  v_now     TIMESTAMPTZ := CURRENT_TIMESTAMP;
BEGIN
  v_limit  := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 200);
  v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;

  SELECT COUNT(*) INTO v_total
    FROM ai_insight i
    WHERE (p_entity_type   IS NULL OR i.entity_type   = p_entity_type)
      AND (p_insight_type  IS NULL OR i.insight_type  = p_insight_type)
      AND (p_language      IS NULL OR i.language      = p_language)
      AND (p_provider      IS NULL OR i.provider      = p_provider)
      AND (p_include_expired OR i.expires_at > v_now)
      AND i.is_active = TRUE;

  SELECT COALESCE(jsonb_agg(row_obj ORDER BY created_at_ord DESC), '[]'::jsonb) INTO v_data
  FROM (
    SELECT
      i.created_at AS created_at_ord,
      jsonb_build_object(
        'id',             i.id,
        'entityType',     i.entity_type,
        'entityId',       i.entity_id,
        'insightType',    i.insight_type,
        'language',       i.language,
        'promptId',       i.prompt_id,
        'provider',       i.provider,
        'modelUsed',      i.model_used,
        'payload',        i.payload,
        'payloadHash',    i.payload_hash,
        'tokensInput',    i.tokens_input,
        'tokensOutput',   i.tokens_output,
        'costUsdMicros',  i.cost_usd_micros,
        'expiresAt',      i.expires_at,
        'isActive',       i.is_active,
        'createdAt',      i.created_at,
        'updatedAt',      i.updated_at
      ) AS row_obj
    FROM ai_insight i
    WHERE (p_entity_type   IS NULL OR i.entity_type   = p_entity_type)
      AND (p_insight_type  IS NULL OR i.insight_type  = p_insight_type)
      AND (p_language      IS NULL OR i.language      = p_language)
      AND (p_provider      IS NULL OR i.provider      = p_provider)
      AND (p_include_expired OR i.expires_at > v_now)
      AND i.is_active = TRUE
    ORDER BY i.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       GREATEST(COALESCE(p_page, 1), 1),
      'limit',      v_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::FLOAT / v_limit)::INTEGER END
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_insight_list(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_insight_list(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, BOOLEAN) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_insight_list(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, BOOLEAN) IS
  'M4 (043) — INVOKER paginated list. RLS narrows visibility to ai.observability.read OR audit.read.all (or polymorphic underlying entity scope).';

-- ============================================================================
-- 11. fn_ai_request_log_list (INVOKER paginated list)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_request_log_list(
  p_page          INTEGER DEFAULT 1,
  p_limit         INTEGER DEFAULT 50,
  p_actor_user_id BIGINT  DEFAULT NULL,
  p_prompt_id     TEXT    DEFAULT NULL,
  p_outcome       TEXT    DEFAULT NULL,
  p_from_date     DATE    DEFAULT NULL,
  p_to_date       DATE    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset  INTEGER;
  v_limit   INTEGER;
  v_total   INTEGER;
  v_data    JSONB;
BEGIN
  IF p_from_date IS NOT NULL AND p_to_date IS NOT NULL THEN
    IF p_from_date > p_to_date THEN
      RAISE EXCEPTION 'fn_ai_request_log_list: %', 'fromDate:fromDate must be on or before toDate'
        USING ERRCODE = '22023';
    END IF;
    IF (p_to_date - p_from_date) > 90 THEN
      RAISE EXCEPTION 'fn_ai_request_log_list: %', 'fromDate:Date range cannot exceed 90 days'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  v_limit  := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
  v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;

  SELECT COUNT(*) INTO v_total
    FROM ai_request_log r
    WHERE (p_actor_user_id IS NULL OR r.actor_user_id = p_actor_user_id)
      AND (p_prompt_id     IS NULL OR r.prompt_id     = p_prompt_id)
      AND (p_outcome       IS NULL OR r.outcome       = p_outcome)
      AND (p_from_date     IS NULL OR r.created_at    >= p_from_date::TIMESTAMPTZ)
      AND (p_to_date       IS NULL OR r.created_at    <  (p_to_date + 1)::TIMESTAMPTZ)
      AND r.is_active = TRUE;

  SELECT COALESCE(jsonb_agg(row_obj ORDER BY created_at_ord DESC), '[]'::jsonb) INTO v_data
  FROM (
    SELECT
      r.created_at AS created_at_ord,
      jsonb_build_object(
        'id',             r.id,
        'requestId',      r.request_id,
        'promptId',       r.prompt_id,
        'mode',           r.mode,
        'actor',          CASE WHEN r.actor_user_id IS NULL THEN NULL ELSE fn_user_get_by_id(r.actor_user_id) END,
        'entityType',     r.entity_type,
        'entityId',       r.entity_id,
        'language',       r.language,
        'provider',       r.provider,
        'modelUsed',      r.model_used,
        'tokensInput',    r.tokens_input,
        'tokensOutput',   r.tokens_output,
        'costUsdMicros',  r.cost_usd_micros,
        'latencyMs',      r.latency_ms,
        'cacheHit',       r.cache_hit,
        'streamMode',     r.stream_mode,
        'outcome',        r.outcome,
        'errorClass',     r.error_class,
        'createdAt',      r.created_at
      ) AS row_obj
    FROM ai_request_log r
    WHERE (p_actor_user_id IS NULL OR r.actor_user_id = p_actor_user_id)
      AND (p_prompt_id     IS NULL OR r.prompt_id     = p_prompt_id)
      AND (p_outcome       IS NULL OR r.outcome       = p_outcome)
      AND (p_from_date     IS NULL OR r.created_at    >= p_from_date::TIMESTAMPTZ)
      AND (p_to_date       IS NULL OR r.created_at    <  (p_to_date + 1)::TIMESTAMPTZ)
      AND r.is_active = TRUE
    ORDER BY r.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       GREATEST(COALESCE(p_page, 1), 1),
      'limit',      v_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::FLOAT / v_limit)::INTEGER END
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_request_log_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_request_log_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, DATE, DATE) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_request_log_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, DATE, DATE) IS
  'M4 (043) — INVOKER paginated list. error_message is intentionally NOT projected (sensitive). actor hydration via fn_user_get_by_id (M1c precedent).';

-- ============================================================================
-- 12. fn_ai_request_log_cost_report (INVOKER aggregate)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_ai_request_log_cost_report(
  p_from_date     DATE,
  p_to_date       DATE,
  p_group_by_user BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_data JSONB;
BEGIN
  IF p_from_date IS NULL OR p_to_date IS NULL THEN
    RAISE EXCEPTION 'fn_ai_request_log_cost_report: %', 'fromDate:fromDate and toDate are required'
      USING ERRCODE = '22023';
  END IF;
  IF p_from_date > p_to_date THEN
    RAISE EXCEPTION 'fn_ai_request_log_cost_report: %', 'fromDate:fromDate must be on or before toDate'
      USING ERRCODE = '22023';
  END IF;
  IF (p_to_date - p_from_date) > 90 THEN
    RAISE EXCEPTION 'fn_ai_request_log_cost_report: %', 'fromDate:Date range cannot exceed 90 days'
      USING ERRCODE = '22023';
  END IF;

  IF p_group_by_user THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'promptId',           prompt_id,
        'actor',              CASE WHEN actor_user_id IS NULL THEN NULL ELSE fn_user_get_by_id(actor_user_id) END,
        'totalCostUsdMicros', total_cost,
        'totalTokensInput',   total_tin,
        'totalTokensOutput',  total_tout,
        'successCount',       success_count,
        'errorCount',         error_count,
        'avgLatencyMs',       avg_latency,
        'cacheHitRatio',      cache_ratio
      ) ORDER BY prompt_id, actor_user_id
    ), '[]'::jsonb) INTO v_data
    FROM (
      SELECT
        r.prompt_id,
        r.actor_user_id,
        SUM(r.cost_usd_micros)::BIGINT                           AS total_cost,
        SUM(r.tokens_input)::BIGINT                              AS total_tin,
        SUM(r.tokens_output)::BIGINT                             AS total_tout,
        COUNT(*) FILTER (WHERE r.outcome = 'success')::INTEGER   AS success_count,
        COUNT(*) FILTER (WHERE r.outcome IN ('error','timeout'))::INTEGER AS error_count,
        AVG(r.latency_ms)::FLOAT                                 AS avg_latency,
        CASE WHEN COUNT(*) = 0 THEN NULL
          ELSE (SUM(CASE WHEN r.cache_hit THEN 1 ELSE 0 END)::FLOAT / COUNT(*))
        END AS cache_ratio
      FROM ai_request_log r
      WHERE r.created_at >= p_from_date::TIMESTAMPTZ
        AND r.created_at <  (p_to_date + 1)::TIMESTAMPTZ
        AND r.is_active = TRUE
      GROUP BY r.prompt_id, r.actor_user_id
    ) agg;
  ELSE
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'promptId',           prompt_id,
        'actor',              NULL,
        'totalCostUsdMicros', total_cost,
        'totalTokensInput',   total_tin,
        'totalTokensOutput',  total_tout,
        'successCount',       success_count,
        'errorCount',         error_count,
        'avgLatencyMs',       avg_latency,
        'cacheHitRatio',      cache_ratio
      ) ORDER BY prompt_id
    ), '[]'::jsonb) INTO v_data
    FROM (
      SELECT
        r.prompt_id,
        SUM(r.cost_usd_micros)::BIGINT                           AS total_cost,
        SUM(r.tokens_input)::BIGINT                              AS total_tin,
        SUM(r.tokens_output)::BIGINT                             AS total_tout,
        COUNT(*) FILTER (WHERE r.outcome = 'success')::INTEGER   AS success_count,
        COUNT(*) FILTER (WHERE r.outcome IN ('error','timeout'))::INTEGER AS error_count,
        AVG(r.latency_ms)::FLOAT                                 AS avg_latency,
        CASE WHEN COUNT(*) = 0 THEN NULL
          ELSE (SUM(CASE WHEN r.cache_hit THEN 1 ELSE 0 END)::FLOAT / COUNT(*))
        END AS cache_ratio
      FROM ai_request_log r
      WHERE r.created_at >= p_from_date::TIMESTAMPTZ
        AND r.created_at <  (p_to_date + 1)::TIMESTAMPTZ
        AND r.is_active = TRUE
      GROUP BY r.prompt_id
    ) agg;
  END IF;

  RETURN jsonb_build_object('data', v_data);
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_request_log_cost_report(DATE, DATE, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_request_log_cost_report(DATE, DATE, BOOLEAN) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_request_log_cost_report(DATE, DATE, BOOLEAN) IS
  'M4 (043) — INVOKER aggregate. 90-day window cap. Groups by prompt_id [+ actor_user_id]. cacheHitRatio is NULL when denominator is zero.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (43, 'm4_ai_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP FUNCTION IF EXISTS fn_ai_request_log_cost_report(DATE, DATE, BOOLEAN);
DROP FUNCTION IF EXISTS fn_ai_request_log_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, DATE, DATE);
DROP FUNCTION IF EXISTS fn_ai_insight_list(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, BOOLEAN);
DROP FUNCTION IF EXISTS fn_contract_version_diff_summary_persist(BIGINT, BIGINT, TEXT);
DROP FUNCTION IF EXISTS fn_contract_ai_summary_persist(BIGINT, BIGINT, TEXT, TEXT, INTEGER);
DROP FUNCTION IF EXISTS fn_ai_prompt_list(BOOLEAN);
DROP FUNCTION IF EXISTS fn_ai_prompt_get(TEXT);
DROP FUNCTION IF EXISTS fn_ai_request_log_check_rate_limit(BIGINT, TEXT);
DROP FUNCTION IF EXISTS fn_ai_request_log_create(UUID, TEXT, TEXT, BIGINT, TEXT, BIGINT, TEXT, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BOOLEAN, BOOLEAN, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS fn_ai_insight_evict_expired(INTEGER);
DROP FUNCTION IF EXISTS fn_ai_insight_upsert(TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BIGINT);
DROP FUNCTION IF EXISTS fn_ai_insight_get_cached(TEXT, BIGINT, TEXT, TEXT, TEXT);
DELETE FROM schema_migrations WHERE version = 43;
COMMIT;
-- ROLLBACK END
