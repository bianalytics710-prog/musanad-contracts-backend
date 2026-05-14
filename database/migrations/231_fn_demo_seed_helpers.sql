-- Migration: 231_fn_demo_seed_helpers.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: 4 seed-loader helpers: fn_demo_seed_load_sources, fn_demo_seed_load_rules,
--              fn_demo_seed_load_templates, fn_demo_seed_load_signals.
--              DEFINER VOLATILE; called by fn_demo_reset OR migration apply step.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- 1. fn_demo_seed_load_sources
CREATE OR REPLACE FUNCTION fn_demo_seed_load_sources()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_inserted INTEGER := 0;
  v_tid UUID;
BEGIN
  -- Loop over all tenants and seed idempotently
  FOR v_tid IN SELECT id FROM tenant WHERE is_active = TRUE LOOP
    INSERT INTO osint_source (tenant_id, source_id, display_name, display_name_ar, kind, source_reliability, enabled, data_classification, is_active, created_at, updated_at)
    VALUES
      (v_tid, 'openweather',           'OpenWeather API',          'واجهة برمجة OpenWeather',          'api',   0.85, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'ncm_uae',               'UAE NCM Warnings RSS',     'تغذية تحذيرات NCM الإمارات',       'rss',   1.00, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'noaa_gfs',              'Open-Meteo (NOAA proxy)',  'Open-Meteo (وكيل NOAA)',           'api',   0.90, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'internal:icv_custom',   'ICV Custom Adapter',       'محول ICV المخصص',                  'internal', 0.95, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'rss_the_national',      'The National RSS',         'تغذية The National RSS',           'rss',   0.80, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'rss_meed',              'MEED RSS',                 'تغذية MEED RSS',                   'rss',   0.80, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'rss_energy_voice',      'Energy Voice RSS',         'تغذية Energy Voice RSS',           'rss',   0.80, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'rss_oil_gas_journal',   'Oil & Gas Journal RSS',    'تغذية مجلة النفط والغاز RSS',     'rss',   0.80, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'rss_reuters_sanctions', 'Reuters Sanctions RSS',    'تغذية رويترز للعقوبات RSS',       'rss',   0.85, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'rss_uae_gov',           'UAE Government RSS',       'تغذية حكومة الإمارات RSS',        'rss',   0.90, TRUE, 'config', TRUE, now(), now()),
      (v_tid, 'mock_social_x',         'Mock X Social Adapter',   'محول X الاجتماعي التجريبي',        'internal', 0.55, TRUE, 'config', TRUE, now(), now())
    ON CONFLICT (tenant_id, source_id) DO NOTHING;
    DECLARE rc INTEGER; BEGIN GET DIAGNOSTICS rc = ROW_COUNT; v_inserted := v_inserted + rc; END;
  END LOOP;

  RETURN jsonb_build_object('inserted', v_inserted);
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_seed_load_sources: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_seed_load_sources() IS 'DEFINER: idempotent seed loader for 11 CRI osint_source rows per tenant. Called by fn_demo_reset and migration 237.';
REVOKE EXECUTE ON FUNCTION fn_demo_seed_load_sources() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_seed_load_sources() TO neondb_owner;

-- 2. fn_demo_seed_load_rules
CREATE OR REPLACE FUNCTION fn_demo_seed_load_rules()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_inserted INTEGER := 0;
  v_tid UUID;
BEGIN
  FOR v_tid IN SELECT id FROM tenant WHERE is_active = TRUE LOOP
    INSERT INTO correlation_rule (tenant_id, rule_id, name, scenario, match_yaml, produce_yaml, is_active, created_at, updated_at)
    VALUES (
      v_tid,
      'rule.weather.fm_eligible',
      'Weather FM Eligible',
      'weather_fm',
      $YAML$signal:
  severity: { gte: high }
  kind: weather
  location: { in_bbox: persian_gulf_or_oman_bbox }
contract:
  contract_type: { in: [o_m, drilling, charter_party] }
  has_clause:
    clause_type: { in: [weather, force_majeure, excusable_delay] }$YAML$,
      $YAML$correlation:
  rule_id: rule.weather.fm_eligible
  alert_roles: [legal_counsel, operations]
  sla_hours: 8$YAML$,
      TRUE, now(), now()
    )
    ON CONFLICT (tenant_id, rule_id) DO NOTHING;
    DECLARE rc INTEGER; BEGIN GET DIAGNOSTICS rc = ROW_COUNT; v_inserted := v_inserted + rc; END;
  END LOOP;

  RETURN jsonb_build_object('inserted', v_inserted);
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_seed_load_rules: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_seed_load_rules() IS 'DEFINER: idempotent seed loader for rule.weather.fm_eligible correlation rule per tenant. Called by fn_demo_reset and migration 238.';
REVOKE EXECUTE ON FUNCTION fn_demo_seed_load_rules() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_seed_load_rules() TO neondb_owner;

-- 3. fn_demo_seed_load_templates
CREATE OR REPLACE FUNCTION fn_demo_seed_load_templates()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_inserted INTEGER := 0;
  v_tid UUID;
BEGIN
  FOR v_tid IN SELECT id FROM tenant WHERE is_active = TRUE LOOP
    INSERT INTO advisory_template (tenant_id, template_id, display_name_en, display_name_ar,
                                   body_template_en, body_template_ar, parameter_schema,
                                   dispatch_channels, is_active, data_classification, created_at, updated_at)
    VALUES
      (v_tid, 'icv_rectification_notice_v1', 'ICV Rectification Notice', '[NEEDS TRANSLATION] إشعار تصحيح ICV',
       'Dear {{counterparty_name}}, your ICV score of {{current_icv_pct}}% is below the required {{target_icv_pct}}%. Please rectify within {{rectification_period_days}} days (Contract: {{contract_id}}).',
       'عزيزي {{counterparty_name}}، درجة ICV الخاصة بك {{current_icv_pct}}٪ أقل من المطلوب {{target_icv_pct}}٪. يرجى التصحيح خلال {{rectification_period_days}} يوماً (العقد: {{contract_id}}).',
       '{"counterparty_name":"string","current_icv_pct":"number","target_icv_pct":"number","rectification_period_days":"integer","contract_id":"bigint"}'::JSONB,
       '{email,in_app}'::TEXT[], TRUE, 'config', now(), now()),

      (v_tid, 'weather_fm_notice_v1', 'Weather FM Notice', '[NEEDS TRANSLATION] إشعار القوة القاهرة للطقس',
       'Dear {{counterparty_name}}, a weather event has breached FM clause thresholds for Contract {{contract_id}}. Event: {{weather_event_summary}}. Threshold: {{weather_threshold_breached}}. Relevant clause: {{fm_clause_text}}. Notice period: {{notice_period_days}} days.',
       'عزيزي {{counterparty_name}}، تجاوز حدث طقس أحكام القوة القاهرة للعقد {{contract_id}}. الحدث: {{weather_event_summary}}. الحد: {{weather_threshold_breached}}. مدة الإشعار: {{notice_period_days}} يوماً.',
       '{"contract_id":"bigint","weather_event_summary":"string","weather_threshold_breached":"string","fm_clause_text":"string","notice_period_days":"integer"}'::JSONB,
       '{email,in_app}'::TEXT[], TRUE, 'config', now(), now()),

      (v_tid, 'esg_concern_memo_v1', 'ESG Concern Memo', '[NEEDS TRANSLATION] مذكرة قلق ESG',
       'ESG Concern for Contract {{contract_id}}: Counterparty {{prime_counterparty_name}} sub-contractor {{sub_contractor_name}} flagged. Concern: {{concern_summary}}. Source: {{source_url}}. Recommended review: {{recommended_review}}.',
       'قلق ESG للعقد {{contract_id}}: المقاول الفرعي {{sub_contractor_name}} للطرف الأساسي {{prime_counterparty_name}} مُعلَّم. المخاوف: {{concern_summary}}. المصدر: {{source_url}}. المراجعة الموصى بها: {{recommended_review}}.',
       '{"contract_id":"bigint","prime_counterparty_name":"string","sub_contractor_name":"string","concern_summary":"string","source_url":"string","recommended_review":"string"}'::JSONB,
       '{in_app}'::TEXT[], TRUE, 'config', now(), now()),

      (v_tid, 'insurance_renewal_reminder_v1', 'Insurance Renewal Reminder', '[NEEDS TRANSLATION] تذكير تجديد التأمين',
       'Insurance Renewal Alert for Contract {{contract_id}}: {{counterparty_name}} certificate type {{certificate_type}} expires on {{expiry_date}} ({{days_to_expiry}} days remaining).',
       'تنبيه تجديد التأمين للعقد {{contract_id}}: شهادة {{certificate_type}} لـ {{counterparty_name}} تنتهي في {{expiry_date}} ({{days_to_expiry}} يوماً متبقياً).',
       '{"contract_id":"bigint","counterparty_name":"string","certificate_type":"string","expiry_date":"date","days_to_expiry":"integer"}'::JSONB,
       '{email,in_app}'::TEXT[], TRUE, 'config', now(), now())
    ON CONFLICT (tenant_id, template_id) DO NOTHING;
    DECLARE rc INTEGER; BEGIN GET DIAGNOSTICS rc = ROW_COUNT; v_inserted := v_inserted + rc; END;
  END LOOP;

  RETURN jsonb_build_object('inserted', v_inserted);
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_seed_load_templates: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_seed_load_templates() IS 'DEFINER: idempotent seed loader for 4 CRI advisory_template rows per tenant. Called by fn_demo_reset and migration 239.';
REVOKE EXECUTE ON FUNCTION fn_demo_seed_load_templates() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_seed_load_templates() TO neondb_owner;

-- 4. fn_demo_seed_load_signals
CREATE OR REPLACE FUNCTION fn_demo_seed_load_signals()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_inserted INTEGER := 0;
  v_tid UUID;
  v_src_id BIGINT;
BEGIN
  FOR v_tid IN SELECT id FROM tenant WHERE is_active = TRUE LOOP
    -- Get or skip mock_social_x source for this tenant
    SELECT id INTO v_src_id FROM osint_source WHERE tenant_id = v_tid AND source_id = 'mock_social_x' LIMIT 1;
    IF v_src_id IS NULL THEN CONTINUE; END IF;

    -- 5 representative ESG signals for reset baseline (full 30 loaded in migration 244)
    INSERT INTO osint_signal (tenant_id, osint_source_id, source_id, kind, signal_kind_subtype,
                              title, summary, severity_v2, url, data_classification, is_active, created_at)
    VALUES
      (v_tid, v_src_id, 'mock_social_x', 'social', 'esg_concern',
       'Labour violation alleged at sub-contractor Alpha', 'Social media reports of labour rights violations at sub-contractor Alpha linked to ADNOC-affiliated prime contractors.',
       'high', 'https://mock.x/esg-alpha-001', 'demo', TRUE, now()),
      (v_tid, v_src_id, 'mock_social_x', 'social', 'esg_concern',
       'Environmental spill near offshore platform Beta', 'Unverified reports of a small hydrocarbon spill near offshore platform Beta operated by a contract supplier.',
       'medium', 'https://mock.x/esg-beta-002', 'demo', TRUE, now()),
      (v_tid, v_src_id, 'mock_social_x', 'social', 'esg_concern',
       'ESG concern: supplier Gamma forced labour allegations', 'Allegations of forced labour practices at supplier Gamma surfaced in international media.',
       'high', 'https://mock.x/esg-gamma-003', 'demo', TRUE, now()),
      (v_tid, v_src_id, 'mock_social_x', 'social', 'esg_concern',
       'Carbon disclosure gap detected for contractor Delta', 'Contractor Delta has not submitted Scope 3 emissions disclosures per contractual ESG annex requirements.',
       'medium', 'https://mock.x/esg-delta-004', 'demo', TRUE, now()),
      (v_tid, v_src_id, 'mock_social_x', 'social', 'esg_concern',
       'Water usage violation flagged at site Epsilon', 'Regulatory inspection flagged excessive water usage at construction site operated by contractor Epsilon.',
       'low', 'https://mock.x/esg-epsilon-005', 'demo', TRUE, now())
    ON CONFLICT DO NOTHING;
    DECLARE rc INTEGER; BEGIN GET DIAGNOSTICS rc = ROW_COUNT; v_inserted := v_inserted + rc; END;
  END LOOP;

  RETURN jsonb_build_object('inserted', v_inserted);
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_seed_load_signals: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_seed_load_signals() IS 'DEFINER: idempotent seed loader for baseline ESG osint_signal rows per tenant. Called by fn_demo_reset.';
REVOKE EXECUTE ON FUNCTION fn_demo_seed_load_signals() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_seed_load_signals() TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (231, '231_fn_demo_seed_helpers', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 231;
-- DROP FUNCTION IF EXISTS fn_demo_seed_load_signals();
-- DROP FUNCTION IF EXISTS fn_demo_seed_load_templates();
-- DROP FUNCTION IF EXISTS fn_demo_seed_load_rules();
-- DROP FUNCTION IF EXISTS fn_demo_seed_load_sources();
-- ============================================================
