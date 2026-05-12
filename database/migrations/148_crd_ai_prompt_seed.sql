-- Migration: 148_crd_ai_prompt_seed.sql
-- Module: M12 / CR-D — Clause Taxonomy + Two-Stage Extractor
-- Description: 1 ai_prompt row (clause-extraction-stage-2 — gpt-4o structured-output).
--              ON CONFLICT (prompt_id) DO NOTHING — idempotent.
--
-- DEFECT FLAG (REPORT DON'T FIX — DB Impl Agent protocol):
--   seed-data.ts seedAiPrompts uses fields: provider, model, mode, system_text, user_text_template.
--   NONE of these columns exist in the actual ai_prompt table (verified live on m0-foundation branch).
--   Actual ai_prompt columns: prompt_id, description_en, description_ar, default_model,
--   default_temperature, default_max_tokens, default_ttl_seconds, supports_streaming,
--   supports_tool_call, public_endpoint, prompt_file_path, rate_limit_per_user_per_hour,
--   rate_limit_per_user_per_day, created_at, updated_at, created_by, updated_by, is_active,
--   data_classification.
--   The system_text / user_text_template seed content is NOT storable in the current schema.
--   This INSERT is adapted to the ACTUAL schema — system_text is documented in the comments
--   below and referenced in BE clause-extraction.service.ts via the prompt_file_path convention.
--   Defect reported in db-impl-report.md as DEFECT-2.
--
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO ai_prompt (
  prompt_id,
  description_en,
  description_ar,
  default_model,
  default_temperature,
  default_max_tokens,
  default_ttl_seconds,
  supports_streaming,
  supports_tool_call,
  public_endpoint,
  prompt_file_path,
  rate_limit_per_user_per_hour,
  rate_limit_per_user_per_day,
  is_active,
  data_classification,
  created_at,
  updated_at
)
VALUES (
  'clause-extraction-stage-2',
  'Stage 2 clause extraction — gpt-4o structured-output. System prompt enforces closed taxonomy constraint + refuse-to-fabricate discipline + JSON output per clause_taxonomy.parameter_schema. User template injects contract region text + fn_clause_taxonomy_list output (50 types + parameter schemas). prompt_hash (SHA-256 of canonical prompt at runtime) stored on contract_clause_extracted.extraction_prompt_hash.',
  '[AR] Stage 2 clause extraction — gpt-4o structured-output. System prompt enforces closed taxonomy constraint + refuse-to-fabricate discipline + JSON output per clause_taxonomy.parameter_schema.',
  'gpt-4o',
  0.0,
  4096,
  300,
  FALSE,
  TRUE,
  FALSE,
  'prompts/clause-extraction-stage-2.md',
  10,
  100,
  TRUE,
  'demo',
  NOW(),
  NOW()
)
ON CONFLICT (prompt_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (148, '148_crd_ai_prompt_seed', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 148;
-- DELETE FROM ai_prompt WHERE prompt_id = 'clause-extraction-stage-2';
-- ============================================================
