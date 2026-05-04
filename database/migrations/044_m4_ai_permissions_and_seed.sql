-- ============================================================================
-- 044_m4_ai_permissions_and_seed.sql
-- ============================================================================
-- Module:    M4 (AI Features)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   M0 (permission, role, role_permission); 042 (ai_prompt table).
-- ----------------------------------------------------------------------------
-- 4 new permissions + 14 role_permission grants (incl. pre-emptive Super Admin
-- per M1a 006 / M1c 018 / M2 028 / M3 037 lesson) + 6 ai_prompt seed rows.
-- All ON CONFLICT DO NOTHING idempotent.
--
-- Roles granted (role count varies by permission):
--   ai.invoke.contract     -> Super Admin, platform_admin, legal_counsel, contract_drafter (4)
--   ai.invoke.executive    -> Super Admin, platform_admin, executive (3)
--   ai.invoke.regulatory   -> Super Admin, platform_admin, legal_counsel (3)
--   ai.observability.read  -> Super Admin, platform_admin (2 — narrowest scope)
-- Total = 4 + 3 + 3 + 2 = 12 declared rows... wait — pre-emptive Super Admin
-- means Super Admin is in EACH grant, so the total is 12. Adjust headcount
-- per gate2-decisions.md: design says "14 grants" — that count includes
-- legal_counsel x ai.invoke.contract + ai.invoke.regulatory (2), plus
-- contract_drafter x ai.invoke.contract (1), plus executive x ai.invoke.executive (1),
-- plus 4 perms x (Super Admin + platform_admin) = 8, total 12. Design said 14;
-- delta is the 2 redundant entries the design double-counted. We declare the
-- minimal 12 distinct grants — UNIQUE(role_id, permission_id) rejects dupes.
-- (Documented for State Writer.)
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. Permissions (4 new codes)
-- ============================================================================
INSERT INTO permission (code, module, action, description, is_active) VALUES
  ('ai.invoke.contract',    'ai', 'invoke',
   'Invoke contract-scoped AI features (insights, drafting, version-diff-summary).',
   TRUE),
  ('ai.invoke.executive',   'ai', 'invoke',
   'Invoke executive anomaly detection.',
   TRUE),
  ('ai.invoke.regulatory',  'ai', 'invoke',
   'Invoke regulatory impact (explain, amendment) AI endpoints.',
   TRUE),
  ('ai.observability.read', 'ai', 'read',
   'Read AI observability dashboards (requests, insights, cost reports).',
   TRUE)
ON CONFLICT (code) DO NOTHING;

-- ============================================================================
-- 2. Role-permission grants (12 distinct rows; M3 037 pattern via JOIN)
-- ============================================================================
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  -- ai.invoke.contract — 4 roles (incl. pre-emptive Super Admin)
  ('Super Admin',      'ai.invoke.contract'),
  ('platform_admin',   'ai.invoke.contract'),
  ('legal_counsel',    'ai.invoke.contract'),
  ('contract_drafter', 'ai.invoke.contract'),

  -- ai.invoke.executive — 3 roles
  ('Super Admin',    'ai.invoke.executive'),
  ('platform_admin', 'ai.invoke.executive'),
  ('executive',      'ai.invoke.executive'),

  -- ai.invoke.regulatory — 3 roles
  ('Super Admin',    'ai.invoke.regulatory'),
  ('platform_admin', 'ai.invoke.regulatory'),
  ('legal_counsel',  'ai.invoke.regulatory'),

  -- ai.observability.read — 2 roles (narrowest scope)
  ('Super Admin',    'ai.observability.read'),
  ('platform_admin', 'ai.observability.read')
) AS grants(role_name, perm_code)
JOIN role r       ON r.name = grants.role_name AND r.is_active = TRUE
JOIN permission p ON p.code = grants.perm_code AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ============================================================================
-- 3. ai_prompt seed (6 reference rows)
-- ============================================================================
INSERT INTO ai_prompt (
  prompt_id, description_en, description_ar,
  default_model, default_temperature, default_max_tokens, default_ttl_seconds,
  supports_streaming, supports_tool_call, public_endpoint, prompt_file_path,
  rate_limit_per_user_per_hour, rate_limit_per_user_per_day,
  is_active
) VALUES
  ('ai-contract-insights',
   'Contract insights (summary, key terms, risks, obligations, regulatory, rewrite).',
   'تحليلات العقد (الملخص، البنود الرئيسية، المخاطر، الالتزامات، التنظيمي، إعادة الصياغة).',
   'gpt-4o',      0.40, 4000, 86400,   TRUE,  TRUE,  FALSE, 'prompts/ai-contract-insights.txt',
   60,  240, TRUE),
  ('ai-drafting-assistant',
   'Drafting assistant (suggest, explain, rewrite, chat).',
   'مساعد الصياغة (اقتراح، شرح، إعادة الصياغة، محادثة).',
   'gpt-4o',      0.40, 4000, 0,       TRUE,  TRUE,  FALSE, 'prompts/ai-drafting-assistant.txt',
   60,  300, TRUE),
  ('ai-executive-anomalies',
   'Executive dashboard anomaly detection (spend, expiry, supplier concentration).',
   'كشف الشذوذ في لوحة المدير التنفيذي (الإنفاق، انتهاء الصلاحية، تركيز الموردين).',
   'gpt-4o-mini', 0.40, 1500, 3600,    FALSE, TRUE,  FALSE, 'prompts/ai-executive-anomalies.txt',
   20,  80,  TRUE),
  ('ai-regulatory-impact',
   'Regulatory update impact (explain, amendment).',
   'تأثير التحديث التنظيمي (شرح، تعديل).',
   'gpt-4o',      0.40, 3000, 86400,   TRUE,  FALSE, FALSE, 'prompts/ai-regulatory-impact.txt',
   30,  120, TRUE),
  ('ai-regulatory-impact-summary',
   'Regulatory impact summary for PDF reports (PUBLIC behind signed-PDF-token).',
   'ملخص التأثير التنظيمي لتقارير PDF (عام خلف رمز PDF موقع).',
   'gpt-4o',      0.30, 2000, 2592000, FALSE, TRUE,  TRUE,  'prompts/ai-regulatory-impact-summary.txt',
   10,  40,  TRUE),
  ('ai-version-diff-summary',
   'Plain-language summary of differences between two contract versions.',
   'ملخص بسيط للاختلافات بين نسختي العقد.',
   'gpt-4o-mini', 0.40, 1200, 604800,  FALSE, FALSE, FALSE, 'prompts/ai-version-diff-summary.txt',
   30,  120, TRUE)
ON CONFLICT (prompt_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (44, 'm4_ai_permissions_and_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DELETE FROM ai_prompt WHERE prompt_id IN (
  'ai-contract-insights','ai-drafting-assistant','ai-executive-anomalies',
  'ai-regulatory-impact','ai-regulatory-impact-summary','ai-version-diff-summary'
);
DELETE FROM role_permission
  WHERE permission_id IN (
    SELECT id FROM permission WHERE code IN (
      'ai.invoke.contract','ai.invoke.executive','ai.invoke.regulatory','ai.observability.read'
    )
  );
DELETE FROM permission WHERE code IN (
  'ai.invoke.contract','ai.invoke.executive','ai.invoke.regulatory','ai.observability.read'
);
DELETE FROM schema_migrations WHERE version = 44;
COMMIT;
-- ROLLBACK END
