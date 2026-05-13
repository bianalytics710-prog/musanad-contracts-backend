-- Migration: 187_crg_seed_ai_prompt_risk_assistant.sql
-- Module: M15 — CR-G (Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant)
-- Description: Seed 6 ai_prompt rows for the CR-G AI Risk Assistant (one per persona)
--              ON CONFLICT (prompt_id) DO UPDATE to make this idempotent
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
  data_classification,
  is_active
) VALUES
  (
    'risk_assistant.qa_executive',
    'CR-G AI Risk Assistant — executive persona prompt. Answers portfolio risk questions with citations to clauses, correlations, signals, and contract IDs.',
    'CR-G مساعد المخاطر بالذكاء الاصطناعي — نسخة المدير التنفيذي.',
    'gpt-4o',
    0.2,
    1500,
    300,
    TRUE,
    FALSE,
    FALSE,
    'prompts/risk-assistant.qa_executive.txt',
    1800,
    14400,
    'demo',
    TRUE
  ),
  (
    'risk_assistant.qa_legal',
    'CR-G AI Risk Assistant — legal counsel persona prompt. Emphasises clause-level risk citations, regulatory exposure, and obligation tracking.',
    'CR-G مساعد المخاطر — نسخة المستشار القانوني.',
    'gpt-4o',
    0.2,
    1500,
    300,
    TRUE,
    FALSE,
    FALSE,
    'prompts/risk-assistant.qa_legal.txt',
    1800,
    14400,
    'demo',
    TRUE
  ),
  (
    'risk_assistant.qa_compliance',
    'CR-G AI Risk Assistant — compliance & ESG persona prompt. Emphasizes regulatory, sanctions, and audit-rights citations.',
    'CR-G مساعد المخاطر — نسخة الامتثال والاستدامة.',
    'gpt-4o',
    0.2,
    1500,
    300,
    TRUE,
    FALSE,
    FALSE,
    'prompts/risk-assistant.qa_compliance.txt',
    1800,
    14400,
    'demo',
    TRUE
  ),
  (
    'risk_assistant.qa_operations',
    'CR-G AI Risk Assistant — operations persona prompt. Emphasizes SLA, delivery, and operational-signal citations.',
    'CR-G مساعد المخاطر — نسخة العمليات.',
    'gpt-4o',
    0.2,
    1500,
    300,
    TRUE,
    FALSE,
    FALSE,
    'prompts/risk-assistant.qa_operations.txt',
    1800,
    14400,
    'demo',
    TRUE
  ),
  (
    'risk_assistant.qa_finance_treasury',
    'CR-G AI Risk Assistant — finance & treasury persona prompt. Emphasizes price-review triggers, FX exposure, and payment-delay citations.',
    'CR-G مساعد المخاطر — نسخة التمويل والخزانة.',
    'gpt-4o',
    0.2,
    1500,
    300,
    TRUE,
    FALSE,
    FALSE,
    'prompts/risk-assistant.qa_finance_treasury.txt',
    1800,
    14400,
    'demo',
    TRUE
  ),
  (
    'risk_assistant.qa_procurement',
    'CR-G AI Risk Assistant — procurement persona prompt (consolidates contract_drafter + contract_approver). Emphasizes supplier-risk, ICV, and backup-supplier citations.',
    'CR-G مساعد المخاطر — نسخة المشتريات.',
    'gpt-4o',
    0.2,
    1500,
    300,
    TRUE,
    FALSE,
    FALSE,
    'prompts/risk-assistant.qa_procurement.txt',
    1800,
    14400,
    'demo',
    TRUE
  )
ON CONFLICT (prompt_id) DO UPDATE SET
  description_en        = EXCLUDED.description_en,
  default_temperature   = EXCLUDED.default_temperature,
  default_max_tokens    = EXCLUDED.default_max_tokens,
  default_ttl_seconds   = EXCLUDED.default_ttl_seconds,
  prompt_file_path      = EXCLUDED.prompt_file_path,
  updated_at            = CURRENT_TIMESTAMP;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (187, '187_crg_seed_ai_prompt_risk_assistant', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 187;
-- DELETE FROM ai_prompt WHERE prompt_id LIKE 'risk_assistant.%';
-- ============================================================
