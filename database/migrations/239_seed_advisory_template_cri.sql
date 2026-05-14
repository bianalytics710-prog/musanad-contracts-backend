-- Migration: 239_seed_advisory_template_cri.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: 4 new advisory_template rows via fn_advisory_template_seed_cri_batch.
--              esg_concern_memo_v1 dispatch_channels={in_app} only (AC-S07-05 no auto-dispatch).
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_advisory_template_seed_cri_batch()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_inserted INTEGER := 0;
  v_tid UUID;
BEGIN
  FOR v_tid IN SELECT id FROM tenant WHERE is_active = TRUE LOOP
    INSERT INTO advisory_template (
      tenant_id, template_id, display_name_en, display_name_ar, draft_type, assigned_approver_role,
      body_template_en, body_template_ar, parameter_schema,
      dispatch_channels, is_active, data_classification, created_at, updated_at
    ) VALUES
      (v_tid, 'icv_rectification_notice_v1',
       'ICV Rectification Notice', 'إشعار تصحيح ICV', 'icv_rectification', 'compliance_esg',
       'Dear {{counterparty_name}}, your ICV score of {{current_icv_pct}}% is below the required {{target_icv_pct}}%. Please rectify within {{rectification_period_days}} days (Contract: {{contract_id}}).',
       'عزيزي {{counterparty_name}}، درجة ICV الخاصة بك {{current_icv_pct}}٪ أقل من المطلوب {{target_icv_pct}}٪. يرجى التصحيح خلال {{rectification_period_days}} يوماً (العقد: {{contract_id}}).',
       '{"counterparty_name":"string","current_icv_pct":"number","target_icv_pct":"number","rectification_period_days":"integer","contract_id":"bigint"}'::JSONB,
       '["email","in_app"]'::JSONB, TRUE, 'demo', now(), now()),

      (v_tid, 'weather_fm_notice_v1',
       'Weather FM Notice', 'إشعار القوة القاهرة للطقس', 'fm_invocation', 'legal_counsel',
       'Dear {{counterparty_name}}, a weather event has breached FM clause thresholds for Contract {{contract_id}}. Event: {{weather_event_summary}}. Threshold: {{weather_threshold_breached}}. Relevant clause: {{fm_clause_text}}. Notice period: {{notice_period_days}} days.',
       'عزيزي {{counterparty_name}}، تجاوز حدث طقس أحكام القوة القاهرة للعقد {{contract_id}}. الحدث: {{weather_event_summary}}. الحد: {{weather_threshold_breached}}. مدة الإشعار: {{notice_period_days}} يوماً.',
       '{"contract_id":"bigint","weather_event_summary":"string","weather_threshold_breached":"string","fm_clause_text":"string","notice_period_days":"integer"}'::JSONB,
       '["email","in_app"]'::JSONB, TRUE, 'demo', now(), now()),

      -- AC-S07-05: ESG Concern Memo — in_app only, no email (manual Compliance review required)
      (v_tid, 'esg_concern_memo_v1',
       'ESG Concern Memo', 'مذكرة قلق ESG', 'esg_concern', 'compliance_esg',
       'ESG Concern for Contract {{contract_id}}: Counterparty {{prime_counterparty_name}} sub-contractor {{sub_contractor_name}} flagged. Concern: {{concern_summary}}. Source: {{source_url}}. Recommended review: {{recommended_review}}.',
       'قلق ESG للعقد {{contract_id}}: المقاول الفرعي {{sub_contractor_name}} للطرف الأساسي {{prime_counterparty_name}} مُعلَّم. المخاوف: {{concern_summary}}. المصدر: {{source_url}}. المراجعة الموصى بها: {{recommended_review}}.',
       '{"contract_id":"bigint","prime_counterparty_name":"string","sub_contractor_name":"string","concern_summary":"string","source_url":"string","recommended_review":"string"}'::JSONB,
       '["in_app"]'::JSONB, TRUE, 'demo', now(), now()),

      (v_tid, 'insurance_renewal_reminder_v1',
       'Insurance Renewal Reminder', 'تذكير تجديد التأمين', 'insurance_renewal', 'legal_counsel',
       'Insurance Renewal Alert for Contract {{contract_id}}: {{counterparty_name}} certificate type {{certificate_type}} expires on {{expiry_date}} ({{days_to_expiry}} days remaining).',
       'تنبيه تجديد التأمين للعقد {{contract_id}}: شهادة {{certificate_type}} لـ {{counterparty_name}} تنتهي في {{expiry_date}} ({{days_to_expiry}} يوماً متبقياً).',
       '{"contract_id":"bigint","counterparty_name":"string","certificate_type":"string","expiry_date":"date","days_to_expiry":"integer"}'::JSONB,
       '["email","in_app"]'::JSONB, TRUE, 'demo', now(), now())
    ON CONFLICT (tenant_id, template_id) DO NOTHING;
    DECLARE rc INTEGER; BEGIN GET DIAGNOSTICS rc = ROW_COUNT; v_inserted := v_inserted + rc; END;
  END LOOP;

  RETURN jsonb_build_object('inserted', v_inserted);
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_template_seed_cri_batch: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_template_seed_cri_batch() IS 'Migration-internal: idempotent seed for 4 CRI advisory_template rows per tenant. esg_concern_memo_v1 dispatch_channels={in_app} only per AC-S07-05.';
REVOKE EXECUTE ON FUNCTION fn_advisory_template_seed_cri_batch() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_seed_cri_batch() TO neondb_owner;

-- Execute the seed
SELECT fn_advisory_template_seed_cri_batch();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (239, '239_seed_advisory_template_cri', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 239;
-- DELETE FROM advisory_template WHERE template_id IN ('icv_rectification_notice_v1','weather_fm_notice_v1','esg_concern_memo_v1','insurance_renewal_reminder_v1');
-- DROP FUNCTION IF EXISTS fn_advisory_template_seed_cri_batch();
-- ============================================================
