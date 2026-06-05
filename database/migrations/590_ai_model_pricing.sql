-- Migration: 590_ai_model_pricing.sql
-- Module: AI governance — centralised model pricing + auto-cost
-- Date: 2026-06-05
--
-- Replaces the per-service hardcoded cost math (e.g. clause-extraction's
-- `Math.round((tokensInput * 5 + tokensOutput * 15) / 1_000_000 * 1_000_000)`)
-- with a single table + helper so:
--   * Pricing updates are one INSERT (new effective_from row) instead of a
--     grep across every service file.
--   * Historical rows stay accurate: a request from March uses March's price,
--     not whatever the live row is today.
--   * Services that left costUsdMicros NULL (advisory drafter, gpt-4o-mini
--     paths) now get a real cost stamped at insert time.
--
-- Schema:
--   ai_model_pricing (provider, model, effective_from, effective_to,
--                     input_price_per_1m_usd, output_price_per_1m_usd,
--                     cached_input_price_per_1m_usd)
--   — only the FROM-side is required. effective_to NULL = "still in force".
--   When OpenAI changes prices, do:
--       UPDATE ai_model_pricing SET effective_to = '2026-07-15' WHERE …;
--       INSERT … new prices effective_from '2026-07-15';
--
-- Helpers:
--   fn_ai_compute_cost_micros(model, tokens_in, tokens_out, at_time)
--     → BIGINT (USD micros = millionths). Looks up the pricing row whose
--       [effective_from, effective_to] window covers at_time.
--
-- fn_ai_request_log_create auto-fills cost when caller passes NULL but
-- tokens are present. Callers that want to override (e.g. test fixtures)
-- can still pass a non-NULL micros value.
--
-- Backfill: rows with tokens_input/output but NULL cost get recomputed in
-- one shot. The append-only deny-update trigger is temporarily disabled
-- for the migration only — restored before COMMIT.

BEGIN;

-- ============================================================
-- 1. ai_model_pricing
-- ============================================================
CREATE TABLE IF NOT EXISTS ai_model_pricing (
  id                              BIGSERIAL PRIMARY KEY,
  provider                        TEXT NOT NULL CHECK (provider IN ('openai','anthropic')),
  model                           TEXT NOT NULL,
  effective_from                  TIMESTAMPTZ NOT NULL,
  effective_to                    TIMESTAMPTZ,
  input_price_per_1m_usd          NUMERIC(10,4) NOT NULL CHECK (input_price_per_1m_usd >= 0),
  output_price_per_1m_usd         NUMERIC(10,4)          CHECK (output_price_per_1m_usd IS NULL OR output_price_per_1m_usd >= 0),
  cached_input_price_per_1m_usd   NUMERIC(10,4)          CHECK (cached_input_price_per_1m_usd IS NULL OR cached_input_price_per_1m_usd >= 0),
  notes                           TEXT,
  is_active                       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by                      BIGINT,
  updated_by                      BIGINT,
  CHECK (effective_to IS NULL OR effective_to > effective_from)
);

COMMENT ON TABLE ai_model_pricing IS
  'M4 (mig 590) — central catalogue of AI model list prices. Rows are time-bounded so historical ai_request_log rows can recompute against the price that was in force at their created_at. NULL effective_to = currently active.';

CREATE INDEX IF NOT EXISTS idx_ai_model_pricing_lookup
  ON ai_model_pricing (provider, model, effective_from DESC)
  WHERE is_active = TRUE;

-- ── Seed current OpenAI prices (USD per 1M tokens, as of 2026-01-01) ─
-- gpt-4o ............ $5 input / $15 output
-- gpt-4o-mini ....... $0.15 input / $0.60 output
-- text-embedding-3-small  $0.02 input (no output)
INSERT INTO ai_model_pricing (provider, model, effective_from, input_price_per_1m_usd, output_price_per_1m_usd, cached_input_price_per_1m_usd, notes)
VALUES
  ('openai', 'gpt-4o',                 '2026-01-01 00:00:00+00', 5.0000,  15.0000,  2.5000,  'Public list price as of 2026-01-01'),
  ('openai', 'gpt-4o-mini',            '2026-01-01 00:00:00+00', 0.1500,   0.6000,  0.0750,  'Public list price as of 2026-01-01'),
  ('openai', 'text-embedding-3-small', '2026-01-01 00:00:00+00', 0.0200,   NULL,    NULL,    'Embedding model — input only')
ON CONFLICT DO NOTHING;

-- ============================================================
-- 2. fn_ai_compute_cost_micros — single source of truth
-- ============================================================
CREATE OR REPLACE FUNCTION fn_ai_compute_cost_micros(
  p_model        TEXT,
  p_tokens_in    INTEGER,
  p_tokens_out   INTEGER,
  p_at_time      TIMESTAMPTZ DEFAULT NOW()
) RETURNS BIGINT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_in_price  NUMERIC(10,4);
  v_out_price NUMERIC(10,4);
  v_cost      NUMERIC(20,6);
BEGIN
  IF p_model IS NULL THEN RETURN NULL; END IF;
  IF p_tokens_in IS NULL AND p_tokens_out IS NULL THEN RETURN NULL; END IF;

  -- Pick the pricing window whose [from, to) brackets the request time.
  -- Most recent effective_from wins if multiple match (defensive).
  SELECT input_price_per_1m_usd, output_price_per_1m_usd
    INTO v_in_price, v_out_price
    FROM ai_model_pricing
    WHERE model = p_model
      AND is_active = TRUE
      AND effective_from <= p_at_time
      AND (effective_to IS NULL OR effective_to > p_at_time)
    ORDER BY effective_from DESC
    LIMIT 1;

  IF v_in_price IS NULL THEN
    -- Unknown model: log nothing, return NULL — caller will see no cost.
    RETURN NULL;
  END IF;

  -- Cost in USD = (tokens_in / 1M) * in_price + (tokens_out / 1M) * out_price.
  -- Convert to micros (millionths of USD) by multiplying by 1e6:
  --   micros = (tokens_in * in_price)  +  (tokens_out * out_price)
  --   (the 1e6 in the denominator and 1e6 in the micros multiplier cancel)
  v_cost := COALESCE(p_tokens_in, 0)::NUMERIC * v_in_price
          + COALESCE(p_tokens_out, 0)::NUMERIC * COALESCE(v_out_price, 0::NUMERIC);

  RETURN ROUND(v_cost)::BIGINT;
END $$;

REVOKE ALL ON FUNCTION fn_ai_compute_cost_micros(TEXT, INTEGER, INTEGER, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_compute_cost_micros(TEXT, INTEGER, INTEGER, TIMESTAMPTZ) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_compute_cost_micros(TEXT, INTEGER, INTEGER, TIMESTAMPTZ) IS
  'Looks up ai_model_pricing for (model, at_time) and returns USD cost in micros (1e-6 USD units). NULL when the model is unknown or tokens are NULL. cost = tokens_in * in_price_per_1m + tokens_out * out_price_per_1m (already micros).';

-- ============================================================
-- 3. fn_ai_request_log_create — auto-fill cost when caller passes NULL
-- ============================================================
-- Same signature, same enum validation, same INSERT. Only diff: if the
-- caller leaves p_cost_usd_micros NULL but provides tokens + model, we
-- compute the cost from ai_model_pricing before the INSERT.
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
  v_id   BIGINT;
  v_cost BIGINT;
BEGIN
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

  -- Auto-fill cost from the pricing catalogue when caller didn't override.
  -- Callers that pre-compute (e.g. test fixtures) keep their explicit value.
  v_cost := p_cost_usd_micros;
  IF v_cost IS NULL AND p_model_used IS NOT NULL
     AND (p_tokens_input IS NOT NULL OR p_tokens_output IS NOT NULL) THEN
    v_cost := fn_ai_compute_cost_micros(p_model_used, p_tokens_input, p_tokens_output, NOW());
  END IF;

  INSERT INTO ai_request_log (
    request_id, prompt_id, mode, actor_user_id,
    entity_type, entity_id, language, provider, model_used,
    tokens_input, tokens_output, cost_usd_micros, latency_ms,
    cache_hit, stream_mode, outcome, error_class, error_message
  ) VALUES (
    p_request_id, p_prompt_id, p_mode, p_actor_user_id,
    p_entity_type, p_entity_id, p_language, p_provider, p_model_used,
    p_tokens_input, p_tokens_output, v_cost, p_latency_ms,
    p_cache_hit, p_stream_mode, p_outcome, p_error_class, p_error_message
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'id',         v_id,
      'requestId',  p_request_id,
      'costMicros', v_cost
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_request_log_create(UUID, TEXT, TEXT, BIGINT, TEXT, BIGINT, TEXT, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BOOLEAN, BOOLEAN, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_request_log_create(UUID, TEXT, TEXT, BIGINT, TEXT, BIGINT, TEXT, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BOOLEAN, BOOLEAN, TEXT, TEXT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_ai_request_log_create(UUID, TEXT, TEXT, BIGINT, TEXT, BIGINT, TEXT, TEXT, TEXT, INTEGER, INTEGER, BIGINT, INTEGER, BOOLEAN, BOOLEAN, TEXT, TEXT, TEXT) IS
  'M4 (043, mig 590 cost auto-fill) — DEFINER append-only insert. If caller passes p_cost_usd_micros = NULL but model + tokens are present, cost is computed via fn_ai_compute_cost_micros against ai_model_pricing. Caller-supplied non-NULL costs are still honoured.';

-- ============================================================
-- 4. Backfill historical rows that have tokens but NULL cost
-- ============================================================
-- ai_request_log is append-only (trg_ai_request_log_deny_update). We need
-- to UPDATE for this one-shot backfill, so disable the trigger only for
-- the duration of this migration.
ALTER TABLE ai_request_log DISABLE TRIGGER trg_ai_request_log_deny_update;

UPDATE ai_request_log
   SET cost_usd_micros = fn_ai_compute_cost_micros(model_used, tokens_input, tokens_output, created_at)
 WHERE cost_usd_micros IS NULL
   AND model_used IS NOT NULL
   AND model_used <> 'unknown'
   AND (tokens_input IS NOT NULL OR tokens_output IS NOT NULL)
   AND fn_ai_compute_cost_micros(model_used, tokens_input, tokens_output, created_at) IS NOT NULL;

ALTER TABLE ai_request_log ENABLE TRIGGER trg_ai_request_log_deny_update;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (590, '590_ai_model_pricing', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- -- Restore the pre-590 fn_ai_request_log_create body from mig 043.
-- -- (No automated rollback for the backfilled cost values — they remain
-- -- in ai_request_log, which is the desired state of historical truth.)
-- DROP FUNCTION IF EXISTS fn_ai_compute_cost_micros(TEXT, INTEGER, INTEGER, TIMESTAMPTZ);
-- DROP TABLE IF EXISTS ai_model_pricing;
-- DELETE FROM schema_migrations WHERE version = 590;
-- COMMIT;
