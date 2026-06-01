-- Migration: 433_rashid_cluster_s_sidebar_modules.sql
-- Unit: Rashid Recipient PM-grade audit fix pass (2026-06-01) — Cluster S
-- Defects addressed:
--   R8 — Desktop sidebar missing Insights entry for contract_recipient.
--        Add contract_recipient to insights_hub.default_role_codes so the
--        Insights link surfaces alongside the existing mobile-bottom-nav
--        + ⌘K palette entries.
--   R28 — Reports page shows "No reports available for your role". Seed a
--         recipient_signing_history report_template per tenant so the Reports
--         surface has at least one role-relevant template.
-- Test-branch-safe: idempotent (jsonb operator-checks; UPSERT on UNIQUE(tenant_id, template_id)).
-- Rollback: remove the role from default_role_codes; mark seeded template inactive.

BEGIN;

-- ─── R8: enable Insights for contract_recipient ──────────────────────────────
UPDATE product_module
   SET default_role_codes = default_role_codes || '"contract_recipient"'::jsonb,
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'insights_hub'
   AND NOT (default_role_codes ? 'contract_recipient');

-- ─── R28: seed a recipient_signing_history report_template per tenant ───────
-- Per-tenant rollout (report_template is tenant-scoped per CR-L).
DO $$
DECLARE
  v_tenant_id UUID;
BEGIN
  FOR v_tenant_id IN SELECT id FROM tenant WHERE is_active = TRUE LOOP
    INSERT INTO report_template (
      tenant_id, template_id, display_name_en, display_name_ar, description,
      report_kind, data_source, parameter_schema, assigned_roles,
      is_scheduled, schedule_cron, schedule_recipients, enabled, is_active,
      data_classification, created_by, updated_by
    ) VALUES (
      v_tenant_id,
      'recipient_signing_history',
      'My signing history',
      'سجل توقيعاتي',
      'Contracts where I am listed as a signatory, with current status + last update + AED value. PDF export of my external-counterparty signing footprint.',
      'pdf',
      'fn_report_data_recipient_signing_history',
      '{
        "type": "object",
        "properties": {
          "windowDays": {"type": "integer", "minimum": 1, "maximum": 365, "default": 365}
        },
        "required": []
      }'::jsonb,
      '["contract_recipient","platform_admin","Super Admin"]'::jsonb,
      FALSE,
      NULL,
      '[]'::jsonb,
      TRUE,
      TRUE,
      'internal',
      1,
      1
    )
    ON CONFLICT (tenant_id, template_id) DO UPDATE
      SET assigned_roles = EXCLUDED.assigned_roles,
          enabled = TRUE,
          is_active = TRUE,
          updated_at = NOW(),
          updated_by = 1;
  END LOOP;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (433, 'R8 — Insights for contract_recipient + R28 — seed recipient_signing_history report', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
--   UPDATE product_module SET default_role_codes = default_role_codes - 'contract_recipient'
--    WHERE key = 'insights_hub';
--   UPDATE report_template SET is_active = FALSE WHERE template_id = 'recipient_signing_history';
--   DELETE FROM schema_migrations WHERE version=433;
-- COMMIT;
-- ROLLBACK END
