-- Migration: 426_dana_cluster_b_drafter_report_templates.sql
-- Unit: Dana Drafter PM-grade audit fix pass (2026-06-01) — Cluster B
-- Defect addressed:
--   D52 — /app/reports renders "No reports available for your role" for Dana
--         because of the 27 existing report_template rows, none have
--         assigned_roles containing 'contract_drafter'. The Reports module
--         IS enabled for the drafter (reports.default_role_codes includes
--         contract_drafter), but no template targets her, so the list is
--         empty.
-- Approach:
--   1. Seed 3 drafter-specific report templates that reflect her workflow:
--        a) drafter_my_pipeline      — My active drafts (Excel + PDF)
--        b) drafter_cycle_time       — My draft → fully-signed cycle time
--        c) drafter_template_usage   — Templates I've used (last 90d)
--   2. Append 'contract_drafter' to the assigned_roles array on a few
--      generally-relevant existing templates (template_usage / clause review
--      backlog / contracts list export) so she has a richer library.
-- Test-branch-safe: idempotent INSERT...ON CONFLICT (template_id) DO NOTHING.
-- Rollback: DELETE the 3 seeded template_id rows; remove drafter from the
-- assigned_roles arrays appended below.

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. Seed 3 drafter-targeted templates (idempotent via NOT EXISTS — table
--    has no unique constraint on template_id, only the id PK).
-- ──────────────────────────────────────────────────────────────────────────
INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, schedule_cron, schedule_recipients,
  enabled, data_classification, created_at, updated_at, created_by, updated_by, is_active
)
SELECT (SELECT id FROM tenant ORDER BY created_at LIMIT 1), 'drafter_my_pipeline', 'My drafting pipeline', 'سير عمل مسوّداتي',
       'Snapshot of every contract you have drafted that is currently in draft, awaiting your action, or queued for signature.',
       'both', 'fn_dashboard_drafter', '{}'::jsonb,
       '["contract_drafter","platform_admin","Super Admin"]'::jsonb,
       FALSE, NULL, '[]'::jsonb,
       TRUE, 'internal', NOW(), NOW(), 1, 1, TRUE
 WHERE NOT EXISTS (SELECT 1 FROM report_template WHERE template_id = 'drafter_my_pipeline');

INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, schedule_cron, schedule_recipients,
  enabled, data_classification, created_at, updated_at, created_by, updated_by, is_active
)
SELECT (SELECT id FROM tenant ORDER BY created_at LIMIT 1), 'drafter_cycle_time', 'My draft → signature cycle time', 'متوسط زمن دورة المسوّدات لديّ',
       'Average days from draft creation to fully-signed by contract type over the last 6 months for contracts you drafted.',
       'excel', 'fn_dashboard_drafter', '{}'::jsonb,
       '["contract_drafter","platform_admin","Super Admin"]'::jsonb,
       FALSE, NULL, '[]'::jsonb,
       TRUE, 'internal', NOW(), NOW(), 1, 1, TRUE
 WHERE NOT EXISTS (SELECT 1 FROM report_template WHERE template_id = 'drafter_cycle_time');

INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, schedule_cron, schedule_recipients,
  enabled, data_classification, created_at, updated_at, created_by, updated_by, is_active
)
SELECT (SELECT id FROM tenant ORDER BY created_at LIMIT 1), 'drafter_template_usage', 'Templates I have used (last 90 days)', 'القوالب التي استخدمتها (آخر 90 يومًا)',
       'List of contract templates used by you in the last 90 days with usage counts and average cycle time per template.',
       'excel', 'contract_template', '{}'::jsonb,
       '["contract_drafter","platform_admin","Super Admin"]'::jsonb,
       FALSE, NULL, '[]'::jsonb,
       TRUE, 'internal', NOW(), NOW(), 1, 1, TRUE
 WHERE NOT EXISTS (SELECT 1 FROM report_template WHERE template_id = 'drafter_template_usage');

-- ──────────────────────────────────────────────────────────────────────────
-- 2. Extend assigned_roles on shared templates that are drafter-relevant
-- ──────────────────────────────────────────────────────────────────────────
UPDATE report_template
   SET assigned_roles = assigned_roles || '"contract_drafter"'::jsonb,
       updated_at = NOW(),
       updated_by = 1
 WHERE template_id IN (
         'legal_clause_review_backlog'  -- review queue is relevant for drafters too
       )
   AND NOT (assigned_roles ? 'contract_drafter');

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (426, 'D52 Dana — seed 3 drafter-targeted report templates + extend 1 shared', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
--   DELETE FROM report_template WHERE template_id IN ('drafter_my_pipeline','drafter_cycle_time','drafter_template_usage');
--   UPDATE report_template SET assigned_roles = assigned_roles - 'contract_drafter'
--    WHERE template_id IN ('legal_clause_review_backlog');
--   DELETE FROM schema_migrations WHERE version = 426;
-- COMMIT;
-- ROLLBACK END
