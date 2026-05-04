-- ============================================================================
-- 042_m4_ai_tables.sql
-- ============================================================================
-- Module:    M4 (AI Features)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   M0 (audit_log, fn_audit_trigger, fn_current_user_has_permission,
--            "user", role, permission, role_permission); 041 (extended redact list).
-- ----------------------------------------------------------------------------
-- 3 new tables + 4 RLS policies + 2 audit triggers + 1 deny-update trigger +
-- 1 supporting trigger function.
--
-- Tables:
--   1. ai_prompt        — reference (code-PK; AUDIT TRIGGER OMITTED per DB-IMPL-I-1)
--   2. ai_insight       — transactional, polymorphic
--   3. ai_request_log   — append-only telemetry
--
-- Trigger functions:
--   - fn_trg_ai_request_log_deny_update  (mirrors M2 fn_trg_approval_decision_deny_update
--     / M3 fn_trg_signature_event_deny_update — RAISES 42501 unconditionally)
--
-- Triggers:
--   - audit_ai_insight_changes        AFTER INSERT OR UPDATE OR DELETE
--   - audit_ai_request_log_changes    AFTER INSERT (append-only mirror)
--   - trg_ai_request_log_deny_update  BEFORE UPDATE (deny)
--
-- 19 indexes total (3 ai_prompt + 8 ai_insight + 6 ai_request_log + 2
-- defence-in-depth FK indexes accounted in those tallies).
--
-- RLS:
--   - ai_prompt: 2 policies (read public; write platform_admin)
--   - ai_insight: 1 SELECT polymorphic; INSERT/UPDATE/DELETE deny-default (RLS
--     RESTRICTIVE — only DEFINER fn_'s write)
--   - ai_request_log: 1 SELECT self-or-admin; INSERT/UPDATE/DELETE deny-default
--     + trg_ai_request_log_deny_update for defence-in-depth.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. ai_prompt — reference table (code-PK, AUDIT TRIGGER OMITTED per DB-IMPL-I-1)
-- ============================================================================
CREATE TABLE ai_prompt (
  prompt_id                    VARCHAR(60) PRIMARY KEY,
  description_en               TEXT        NOT NULL,
  description_ar               TEXT        NOT NULL,
  default_model                VARCHAR(80) NOT NULL,
  default_temperature          NUMERIC(3,2) NOT NULL CHECK (default_temperature BETWEEN 0 AND 2),
  default_max_tokens           INTEGER     NOT NULL CHECK (default_max_tokens > 0),
  default_ttl_seconds          INTEGER     NOT NULL CHECK (default_ttl_seconds >= 0),
  supports_streaming           BOOLEAN     NOT NULL,
  supports_tool_call           BOOLEAN     NOT NULL,
  public_endpoint              BOOLEAN     NOT NULL DEFAULT FALSE,
  prompt_file_path             VARCHAR(255) NOT NULL,
  rate_limit_per_user_per_hour INTEGER     NOT NULL CHECK (rate_limit_per_user_per_hour > 0),
  rate_limit_per_user_per_day  INTEGER     NOT NULL CHECK (rate_limit_per_user_per_day  > 0),
  created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE ai_prompt IS
  'M4 reference table for AI prompt configuration. Code-PK (prompt_id) -> AUDIT TRIGGER OMITTED per DB-IMPL-I-1 (fn_audit_trigger references NEW.id; ai_prompt has no id column). Same precedent as M3 signature_party_side / signature_method.';

CREATE INDEX idx_ai_prompt_created_by ON ai_prompt(created_by);
CREATE INDEX idx_ai_prompt_updated_by ON ai_prompt(updated_by);
CREATE INDEX idx_ai_prompt_active     ON ai_prompt(prompt_id) WHERE is_active = TRUE;

-- ============================================================================
-- 2. ai_insight — transactional, polymorphic
-- ============================================================================
CREATE TABLE ai_insight (
  id              BIGSERIAL PRIMARY KEY,
  entity_type     VARCHAR(40) NOT NULL,
  entity_id       BIGINT,
  insight_type    VARCHAR(60) NOT NULL,
  language        VARCHAR(8)  NOT NULL CHECK (language IN ('en','ar','bilingual')),
  payload_hash    VARCHAR(64) NOT NULL,
  prompt_id       VARCHAR(60) NOT NULL REFERENCES ai_prompt(prompt_id) ON DELETE RESTRICT,
  provider        VARCHAR(40) NOT NULL CHECK (provider IN ('openai','anthropic')),
  model_used      VARCHAR(80) NOT NULL,
  payload         JSONB       NOT NULL,
  tokens_input    INTEGER,
  tokens_output   INTEGER,
  cost_usd_micros BIGINT,
  expires_at      TIMESTAMP WITH TIME ZONE NOT NULL,
  created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by      BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by      BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE ai_insight IS
  'M4 transactional cache + audit store for AI outputs. Polymorphic via (entity_type, entity_id) — closest precedent is M0 audit_log.table_name+record_id. UNIQUE INDEX uses COALESCE(entity_id, 0) sentinel for NULL safety on executive_dashboard rows. Direct INSERT/UPDATE/DELETE denied by RLS — only DEFINER fn_ai_insight_upsert + fn_ai_insight_evict_expired write. Soft-delete only.';

-- Composite UNIQUE INDEX with COALESCE for NULL-safe uniqueness (Q6 lock).
-- Postgres treats NULL as DISTINCT in UNIQUE indexes by default; COALESCE-to-0
-- ensures cross-NULL uniqueness for executive_dashboard rows.
CREATE UNIQUE INDEX idx_ai_insight_unique_active
  ON ai_insight (entity_type, COALESCE(entity_id, 0::BIGINT), insight_type, language)
  WHERE is_active = TRUE;

CREATE INDEX idx_ai_insight_payload_hash_active
  ON ai_insight (payload_hash) WHERE is_active = TRUE;

CREATE INDEX idx_ai_insight_expiry_sweep
  ON ai_insight (expires_at)
  WHERE expires_at IS NOT NULL AND is_active = TRUE;

CREATE INDEX idx_ai_insight_prompt_id   ON ai_insight(prompt_id);
CREATE INDEX idx_ai_insight_created_by  ON ai_insight(created_by);
CREATE INDEX idx_ai_insight_updated_by  ON ai_insight(updated_by);
CREATE INDEX idx_ai_insight_active      ON ai_insight(id) WHERE is_active = TRUE;
CREATE INDEX idx_ai_insight_by_entity
  ON ai_insight (entity_type, entity_id, created_at DESC) WHERE is_active = TRUE;

-- ============================================================================
-- 3. ai_request_log — append-only telemetry
-- ============================================================================
CREATE TABLE ai_request_log (
  id              BIGSERIAL PRIMARY KEY,
  request_id      UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  prompt_id       VARCHAR(60) NOT NULL REFERENCES ai_prompt(prompt_id) ON DELETE RESTRICT,
  mode            VARCHAR(40),
  actor_user_id   BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  entity_type     VARCHAR(40),
  entity_id       BIGINT,
  language        VARCHAR(8) NOT NULL CHECK (language IN ('en','ar','bilingual')),
  provider        VARCHAR(40) NOT NULL CHECK (provider IN ('openai','anthropic')),
  model_used      VARCHAR(80) NOT NULL,
  tokens_input    INTEGER,
  tokens_output   INTEGER,
  cost_usd_micros BIGINT,
  latency_ms      INTEGER,
  cache_hit       BOOLEAN NOT NULL DEFAULT FALSE,
  stream_mode     BOOLEAN NOT NULL DEFAULT FALSE,
  outcome         VARCHAR(20) NOT NULL CHECK (outcome IN ('success','error','timeout','rate_limited','cancelled')),
  error_class     VARCHAR(80),
  error_message   TEXT,
  created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE ai_request_log IS
  'M4 append-only audit + telemetry log for every AI request. Mirrors M2 approval_decision + M3 signature_event append-only pattern. UPDATE blocked by trg_ai_request_log_deny_update (defence-in-depth). Direct INSERT denied by RLS — only DEFINER fn_ai_request_log_create writes. error_message is pre-sanitised at controller (Pino redact) before fn call; redact list extension in 041 is defence-in-depth.';

CREATE INDEX idx_ai_request_log_actor_prompt_created
  ON ai_request_log (actor_user_id, prompt_id, created_at);

CREATE INDEX idx_ai_request_log_prompt_outcome_created
  ON ai_request_log (prompt_id, outcome, created_at DESC);

CREATE INDEX idx_ai_request_log_error_tail
  ON ai_request_log (created_at DESC) WHERE outcome <> 'success';

CREATE INDEX idx_ai_request_log_entity_created
  ON ai_request_log (entity_type, entity_id, created_at DESC);

CREATE INDEX idx_ai_request_log_prompt_id ON ai_request_log(prompt_id);

CREATE INDEX idx_ai_request_log_active ON ai_request_log(id) WHERE is_active = TRUE;

-- ============================================================================
-- 4. fn_trg_ai_request_log_deny_update + trigger (append-only enforcement)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_trg_ai_request_log_deny_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'fn_trg_ai_request_log_deny_update: ai_request_log is append-only'
    USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION fn_trg_ai_request_log_deny_update() IS
  'M4 (042) — BEFORE UPDATE trigger function for ai_request_log. RAISES 42501 unconditionally. Mirrors M2 fn_trg_approval_decision_deny_update / M3 fn_trg_signature_event_deny_update.';

CREATE TRIGGER trg_ai_request_log_deny_update
  BEFORE UPDATE ON ai_request_log
  FOR EACH ROW EXECUTE FUNCTION fn_trg_ai_request_log_deny_update();

-- ============================================================================
-- 5. Audit triggers
-- ============================================================================
-- ai_insight: standard audit on all DML
CREATE TRIGGER audit_ai_insight_changes
  AFTER INSERT OR UPDATE OR DELETE ON ai_insight
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ai_request_log: append-only — audit on INSERT only (mirrors M3 audit_signature_event_changes)
CREATE TRIGGER audit_ai_request_log_changes
  AFTER INSERT ON ai_request_log
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ai_prompt: AUDIT TRIGGER OMITTED — code-PK incompatible with fn_audit_trigger NEW.id
-- (Same precedent as M3 signature_party_side / signature_method.)

-- ============================================================================
-- 6. RLS — ENABLE on all 3 tables
-- ============================================================================
ALTER TABLE ai_prompt      ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_insight     ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_request_log ENABLE ROW LEVEL SECURITY;

-- 6.1 ai_prompt policies
CREATE POLICY ai_prompt_read ON ai_prompt
  FOR SELECT
  USING (TRUE);

CREATE POLICY ai_prompt_write_admin ON ai_prompt
  FOR ALL
  USING (
    fn_current_user_has_permission('platform_admin')
    OR fn_current_user_has_permission('ai.observability.read')
  )
  WITH CHECK (
    fn_current_user_has_permission('platform_admin')
    OR fn_current_user_has_permission('ai.observability.read')
  );

-- 6.2 ai_insight — SELECT polymorphic dispatch; INSERT/UPDATE/DELETE deny-default
CREATE POLICY ai_insight_select_scope ON ai_insight
  FOR SELECT
  USING (
    fn_current_user_has_permission('ai.observability.read')
    OR fn_current_user_has_permission('audit.read.all')
    OR (entity_type = 'contract' AND EXISTS (
      SELECT 1 FROM contract c
      WHERE c.id = ai_insight.entity_id
        AND c.is_active = TRUE
    ))
    OR (entity_type = 'contract_version' AND EXISTS (
      SELECT 1 FROM contract_version cv
      JOIN contract c ON c.id = cv.contract_id
      WHERE cv.id = ai_insight.entity_id
        AND cv.is_active = TRUE
        AND c.is_active = TRUE
    ))
    OR (entity_type = 'executive_dashboard' AND (
      fn_current_user_has_permission('ai.invoke.executive')
      OR fn_current_user_has_permission('platform_admin')
    ))
    OR (entity_type IN ('regulatory_update','regulatory_update_summary') AND
      fn_current_user_has_permission('ai.invoke.regulatory'))
  );

-- 6.3 ai_request_log — self-or-admin SELECT; INSERT/UPDATE/DELETE deny-default
CREATE POLICY ai_request_log_select_self_or_admin ON ai_request_log
  FOR SELECT
  USING (
    actor_user_id = NULLIF(current_setting('app.current_user_id', TRUE), '')::BIGINT
    OR fn_current_user_has_permission('ai.observability.read')
    OR fn_current_user_has_permission('audit.read.all')
  );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (42, 'm4_ai_tables', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP TRIGGER IF EXISTS trg_ai_request_log_deny_update ON ai_request_log;
DROP TRIGGER IF EXISTS audit_ai_request_log_changes   ON ai_request_log;
DROP TRIGGER IF EXISTS audit_ai_insight_changes       ON ai_insight;
DROP FUNCTION IF EXISTS fn_trg_ai_request_log_deny_update();

DROP POLICY IF EXISTS ai_request_log_select_self_or_admin ON ai_request_log;
DROP POLICY IF EXISTS ai_insight_select_scope             ON ai_insight;
DROP POLICY IF EXISTS ai_prompt_write_admin               ON ai_prompt;
DROP POLICY IF EXISTS ai_prompt_read                      ON ai_prompt;

DROP TABLE IF EXISTS ai_request_log;
DROP TABLE IF EXISTS ai_insight;
DROP TABLE IF EXISTS ai_prompt;
DELETE FROM schema_migrations WHERE version = 42;
COMMIT;
-- ROLLBACK END
