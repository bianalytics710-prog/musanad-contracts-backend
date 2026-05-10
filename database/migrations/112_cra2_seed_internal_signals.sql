-- Migration: 112_cra2_seed_internal_signals.sql
-- Module: M8 — Internal Signal Data Path (CR-A2)
-- Description: Three-part seed pack (each block fully idempotent on re-apply):
--                (a) 1 osint_source row — source_id='internal:harness'
--                    (CRITICAL precondition; without this fn_internal_signal_ingest raises
--                    'Source not registered: internal:harness').
--                (b) 8 internal_signal_kind catalogue rows for ADNOC tenant.
--                (c) 1 EPC counterparty + 1 EPC demo contract + 10 internal-signal demo
--                    rows via PERFORM fn_internal_signal_ingest() — back-dated relative
--                    to now() at 170/120/60/30/90/75/50/45/20/15 days so AC-S3-01 invariant
--                    count_in_180_days >= 3 holds forever (Q-DA5 RELATIVE).
-- ROUTE B PATCH (2026-05-09): live schema audit found
--   * party.party_type CHECK enum is ('individual','company') — design's 'counterparty' value
--     does NOT exist (M8-DBI-002).
--   * contract.title (used in design §11.3 ILIKE lookup) does NOT exist — actual columns are
--     title_en + title_ar (M8-DBI-001).
--   * No EPC contract exists in seed data → previous title-ILIKE lookup returned NULL.
--   Resolution: pre-seed an EPC company party + an EPC master_services contract WITHIN this
--   migration, then PERFORM fn_internal_signal_ingest with literal contract_id / vendor_id.
--   * Live `fn_internal_signal_ingest` takes ONE arg (p_payload) — not two — and reads actor
--     from app.current_user_id GUC. Patch sets that GUC instead of passing actor explicitly.
--   * `party` table has no UNIQUE constraint on trade_license_number — idempotency uses a
--     pre-INSERT SELECT lookup instead of ON CONFLICT.
-- Rollback: see ROLLBACK section below.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ----------------------------------------------------------------
-- (a) osint_source — 'internal:harness' row
--     Re-applies harmlessly on re-run (already applied in earlier
--     successful execution of this same migration; (c) is the only
--     part that previously failed and is now patched).
-- ----------------------------------------------------------------
INSERT INTO osint_source (
  tenant_id, source_id, display_name, display_name_ar, kind, url, format,
  refresh_seconds, source_reliability, enabled, rate_limit, severity_mapping,
  geography_filter, licensing_note, metadata, data_classification
) VALUES
('00000000-0000-0000-0000-000000000001','internal:harness','Internal Signal Harness','مُلقّن الإشارات الداخلية','internal',
 NULL,'api',86400,1.00,TRUE,
 NULL,NULL,NULL,'Internal first-party data — no external license.',
 '{"adapterClass":"none","kind":"internal","note":"Push-only source — fn_internal_signal_ingest writes here. refresh_seconds is cosmetic (no fetch loop). source_reliability=1.00 (first-party)."}'::jsonb,
 'demo')
ON CONFLICT (tenant_id, source_id) DO NOTHING;

-- ----------------------------------------------------------------
-- (b) internal_signal_kind — 8 catalogue rows for ADNOC tenant
-- ----------------------------------------------------------------
INSERT INTO internal_signal_kind (
  tenant_id, signal_type, display_name, display_name_ar, description,
  parameter_schema, default_severity
) VALUES
-- 1. milestone_slippage
('00000000-0000-0000-0000-000000000001','milestone_slippage',
  'Milestone Slippage','تأخر معلَم تنفيذ',
  'A contract milestone has slipped past its scheduled delivery date.',
  '{"required":["contractId","milestoneRef","observedAt"],"optional":["severityCalcInput","daysOverdue"]}'::jsonb,
  'high'),

-- 2. sla_breach
('00000000-0000-0000-0000-000000000001','sla_breach',
  'SLA Breach','إخلال باتفاقية مستوى الخدمة',
  'A service-level metric has breached its threshold.',
  '{"required":["contractId","observedAt"],"optional":["severityCalcInput","metricRef","thresholdValue","actualValue"]}'::jsonb,
  'high'),

-- 3. payment_delay
('00000000-0000-0000-0000-000000000001','payment_delay',
  'Payment Delay','تأخر دفع',
  'A vendor invoice has aged past its due date.',
  '{"required":["contractId","invoiceRef","observedAt","daysOverdue"],"optional":["severityCalcInput","amountAed"]}'::jsonb,
  'medium'),

-- 4. invoice_dispute
('00000000-0000-0000-0000-000000000001','invoice_dispute',
  'Invoice Dispute','نزاع على فاتورة',
  'An invoice has been formally disputed by either party.',
  '{"required":["contractId","invoiceRef","observedAt"],"optional":["severityCalcInput","disputeReason"]}'::jsonb,
  'medium'),

-- 5. vendor_incident
('00000000-0000-0000-0000-000000000001','vendor_incident',
  'Vendor Incident','حادث متعلق بالمورّد',
  'A vendor has experienced an incident affecting performance, safety, or reputation.',
  '{"required":["vendorId","observedAt"],"optional":["contractId","severityCalcInput","incidentRef","incidentCategory"]}'::jsonb,
  'high'),

-- 6. ics_incident
('00000000-0000-0000-0000-000000000001','ics_incident',
  'ICS / OT Incident','حادث في أنظمة التحكم الصناعية',
  'An industrial-control or operational-technology incident has been logged.',
  '{"required":["observedAt"],"optional":["contractId","vendorId","severityCalcInput","ticketRef","systemName"]}'::jsonb,
  'critical'),

-- 7. icv_status_change
('00000000-0000-0000-0000-000000000001','icv_status_change',
  'ICV Status Change','تغيّر حالة الشهادة الإقليمية',
  'A vendor In-Country-Value status or ICV certificate has changed.',
  '{"required":["vendorId","observedAt"],"optional":["contractId","severityCalcInput","oldStatus","newStatus"]}'::jsonb,
  'medium'),

-- 8. certificate_expiry
('00000000-0000-0000-0000-000000000001','certificate_expiry',
  'Certificate Expiry','انتهاء صلاحية شهادة',
  'A required certificate is approaching or past expiry.',
  '{"required":["observedAt"],"optional":["contractId","vendorId","severityCalcInput","certificateType","expiresAt"]}'::jsonb,
  'medium')
ON CONFLICT (tenant_id, signal_type) DO NOTHING;

-- ----------------------------------------------------------------
-- (c) EPC counterparty + EPC contract precursor + 10 internal-signal demo rows
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_tenant_id       UUID    := '00000000-0000-0000-0000-000000000001'::uuid;
  v_admin_id        BIGINT;
  v_counterparty_id BIGINT;
  v_contract_id     BIGINT;
  v_signal_result   JSONB;
  v_now_iso         TEXT;
  v_epc_license     TEXT    := 'EPC-CRA2-DEMO-001';
  v_epc_contract_no TEXT    := 'CRA2-EPC-2026-001';
BEGIN
  -- Bootstrap admin actor — drives both fn_current_user_has_permission()
  -- and the v_actor BIGINT lookup inside fn_osint_signal_upsert.
  SELECT id INTO v_admin_id FROM "user" WHERE email = 'admin@musanad.local' LIMIT 1;
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'Bootstrap admin user not found — cannot seed CR-A2 EPC scenario';
  END IF;

  -- Set tenant + actor GUCs.  Both fn_internal_signal_ingest and
  -- fn_osint_signal_upsert read these via current_setting(...).
  PERFORM set_config('app.current_tenant_id', v_tenant_id::text, true);
  PERFORM set_config('app.current_user_id',   v_admin_id::text, true);

  -- ------------------------------------------------------------
  -- (c-pre-1) EPC counterparty party — idempotent via SELECT-first
  --   No UNIQUE constraint on party.trade_license_number in live schema,
  --   so we look up by (party_type, trade_license_number, is_seed) and
  --   only INSERT when missing.
  -- ------------------------------------------------------------
  SELECT id INTO v_counterparty_id
    FROM party
   WHERE party_type = 'company'
     AND trade_license_number = v_epc_license
     AND is_seed = TRUE
   LIMIT 1;

  IF v_counterparty_id IS NULL THEN
    INSERT INTO party (
      party_type, name_en, name_ar, trade_license_number, trade_license_issuer,
      emirate, free_zone, country, contact_email, contact_phone, registered_address,
      is_seed, created_by, updated_by, is_active, is_verified
    ) VALUES (
      'company',
      'EPC Pipeline Contractors LLC',
      'شركة المقاولين لإنشاء خطوط الأنابيب EPC',
      v_epc_license,
      'Abu Dhabi Department of Economic Development',
      'abu_dhabi', NULL, 'United Arab Emirates',
      'pmo@epc-pipelines-demo.local', '+971-2-555-0199',
      'Plot 42, ICAD II, Abu Dhabi',
      TRUE, v_admin_id, v_admin_id, TRUE, TRUE
    )
    RETURNING id INTO v_counterparty_id;
  END IF;

  -- ------------------------------------------------------------
  -- (c-pre-2) EPC demo contract — idempotent via SELECT-first then
  --   ON CONFLICT (contract_number) belt-and-braces. contract.contract_type
  --   has no CHECK enum in live schema, but we use 'master_services' to
  --   align with existing sample contract_type values rather than
  --   introducing a new 'epc' value.
  -- ------------------------------------------------------------
  SELECT id INTO v_contract_id
    FROM contract
   WHERE contract_number = v_epc_contract_no
   LIMIT 1;

  IF v_contract_id IS NULL THEN
    INSERT INTO contract (
      contract_number, title_en, title_ar,
      contract_type, status, language,
      our_party_id, counterparty_id,
      value_aed, currency, start_date, end_date,
      emirate, governing_law,
      drafted_by, created_by, updated_by, is_active
    ) VALUES (
      v_epc_contract_no,
      'EPC Pipeline Construction Master Services Agreement',
      'اتفاقية الخدمات الرئيسية لإنشاء خطوط الأنابيب EPC',
      'master_services',
      'active', 'bilingual',
      NULL, v_counterparty_id,
      4500000.00, 'AED',
      (now() - interval '300 days')::date,
      (now() + interval '730 days')::date,
      'abu_dhabi', 'uae_federal',
      v_admin_id, v_admin_id, v_admin_id, TRUE
    )
    ON CONFLICT (contract_number) DO UPDATE
      SET counterparty_id = EXCLUDED.counterparty_id
    RETURNING id INTO v_contract_id;
  END IF;

  -- VERIFY both ids before proceeding
  IF v_counterparty_id IS NULL OR v_contract_id IS NULL THEN
    RAISE EXCEPTION 'CR-A2 seed precursor failed: counterparty_id=% contract_id=%',
      v_counterparty_id, v_contract_id;
  END IF;

  RAISE NOTICE 'CR-A2 EPC seed precursor: counterparty=% contract=% admin=%',
    v_counterparty_id, v_contract_id, v_admin_id;

  -- ============================================================
  -- 10× fn_internal_signal_ingest calls — all back-dated relative to now()
  -- so AC-S3-01 (count_in_180_days >= 3) holds forever.
  -- Note: fn_internal_signal_ingest in live DB takes ONE arg (p_payload).
  -- ============================================================

  -- 4× milestone_slippage on EPC contract — 170/120/60/30 days back
  v_now_iso := (now() - interval '170 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'milestone_slippage',
    'contractId',         v_contract_id,
    'milestoneRef',       'M-2026-Q1',
    'observedAt',         v_now_iso,
    'severityCalcInput',  jsonb_build_object('daysSlippage', 14)
  ));
  RAISE NOTICE 'CR-A2 milestone_slippage 170d: %', v_signal_result;

  v_now_iso := (now() - interval '120 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'milestone_slippage',
    'contractId',         v_contract_id,
    'milestoneRef',       'M-2026-Q2',
    'observedAt',         v_now_iso,
    'severityCalcInput',  jsonb_build_object('daysSlippage', 21)
  ));

  v_now_iso := (now() - interval '60 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'milestone_slippage',
    'contractId',         v_contract_id,
    'milestoneRef',       'M-2026-Q3',
    'observedAt',         v_now_iso,
    'severityCalcInput',  jsonb_build_object('daysSlippage', 7)
  ));

  v_now_iso := (now() - interval '30 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'milestone_slippage',
    'contractId',         v_contract_id,
    'milestoneRef',       'M-2026-Q4',
    'observedAt',         v_now_iso,
    'severityCalcInput',  jsonb_build_object('daysSlippage', 35)
  ));

  -- 2× sla_breach on EPC contract — 45d / 15d back
  v_now_iso := (now() - interval '45 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'sla_breach',
    'contractId',         v_contract_id,
    'observedAt',         v_now_iso,
    'severityCalcInput',  jsonb_build_object('hoursOverSla', 36)
  ));

  v_now_iso := (now() - interval '15 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'sla_breach',
    'contractId',         v_contract_id,
    'observedAt',         v_now_iso,
    'severityCalcInput',  jsonb_build_object('hoursOverSla', 18)
  ));

  -- 2× payment_delay on EPC contract — 90d / 50d back
  --   parameter_schema requires daysOverdue at top level (not just in severityCalcInput).
  v_now_iso := (now() - interval '90 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'payment_delay',
    'contractId',         v_contract_id,
    'invoiceRef',         'INV-2026-0387',
    'observedAt',         v_now_iso,
    'daysOverdue',        28,
    'severityCalcInput',  jsonb_build_object('daysOverdue', 28)
  ));

  v_now_iso := (now() - interval '50 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'payment_delay',
    'contractId',         v_contract_id,
    'invoiceRef',         'INV-2026-0421',
    'observedAt',         v_now_iso,
    'daysOverdue',        14,
    'severityCalcInput',  jsonb_build_object('daysOverdue', 14)
  ));

  -- 2× icv_status_change on EPC counterparty (vendor) — 75d / 20d back
  v_now_iso := (now() - interval '75 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'icv_status_change',
    'vendorId',           v_counterparty_id,
    'observedAt',         v_now_iso,
    'severityCalcInput',  jsonb_build_object('previousLevel', 'silver', 'newLevel', 'bronze')
  ));

  v_now_iso := (now() - interval '20 days')::timestamptz::text;
  v_signal_result := fn_internal_signal_ingest(jsonb_build_object(
    'signalType',         'icv_status_change',
    'vendorId',           v_counterparty_id,
    'observedAt',         v_now_iso,
    'severityCalcInput',  jsonb_build_object('previousLevel', 'bronze', 'newLevel', 'silver')
  ));

  RAISE NOTICE 'CR-A2 seed pack complete';
END $$;

-- ----------------------------------------------------------------
-- Record this migration
-- ----------------------------------------------------------------
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (112, '112_cra2_seed_internal_signals', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM osint_signal
--  WHERE source_id = 'internal:harness'
--    AND kind = 'internal'
--    AND tenant_id = '00000000-0000-0000-0000-000000000001';
-- DELETE FROM contract WHERE contract_number = 'CRA2-EPC-2026-001';
-- DELETE FROM party
--  WHERE party_type = 'company'
--    AND trade_license_number = 'EPC-CRA2-DEMO-001'
--    AND is_seed = TRUE;
-- DELETE FROM internal_signal_kind
--  WHERE tenant_id = '00000000-0000-0000-0000-000000000001';
-- DELETE FROM osint_source
--  WHERE source_id = 'internal:harness'
--    AND tenant_id = '00000000-0000-0000-0000-000000000001';
-- DELETE FROM schema_migrations WHERE version = 112;
-- COMMIT;
-- ============================================================
