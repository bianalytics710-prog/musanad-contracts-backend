-- Migration: 193_unit3_seed_payment_delay_signals_and_rule.sql
-- Unit: Unit-3 (R-FT — Payment Delay Register depth)
-- Description: Seed 3 osint_signal rows with kind='internal' subtype='payment_delay'
--              (with proper days_overdue / invoice_ref / amount_aed metadata) +
--              one correlation_rule (rule.payment.delay_detect) + 3 active
--              correlation rows linking each signal to a real demo contract.
--
--              fn_dashboard_finance_treasury already wires paymentDelayRegister
--              from correlation JOIN osint_signal kind='internal'
--              subtype='payment_delay' — this migration ONLY seeds the data,
--              it does NOT extend the function (per decisions AD-8 fn-extend
--              is preserved; the fn already handles the JOIN).
--
--              IMPORTANT: portable across Neon branches — picks the first 3
--              eligible active contracts (status in active/fully_signed/signed
--              with non-null counterparty_id) dynamically on each branch
--              rather than hard-coding contract IDs. metadata.invoice_ref +
--              dedup_hash are derived from contract_number so re-application
--              is idempotent per branch.
-- Reference: decisions AD-8, GAP-REPORT-FINANCE-TREASURY H2, R-FT3 round.
-- Rollback: see ROLLBACK section.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- 1. Seed correlation_rule rule.payment.delay_detect (if not already present).
INSERT INTO correlation_rule (
  tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
  match_yaml, produce_yaml, version_hash, data_classification,
  created_at, created_by, updated_at, updated_by, is_active
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'rule.payment.delay_detect',
  'Detect overdue invoice payment vs. counterparty contract',
  'كشف التأخر في سداد الفاتورة مقابل عقد الطرف المقابل',
  'payment',
  TRUE,
  jsonb_build_object('threshold_days_overdue', 14, 'category', 'cash_flow_risk'),
  $YAML$signal:
  kind: [internal]
  source_id: internal:harness
  signal_kind_subtype: payment_delay
  raw_field: { path: days_overdue, gte: 14 }
contract:
  status: [active, fully_signed, signed]
  has_counterparty: true
joins:
  entity_match: signal.counterparty_id == contract.counterparty_id
$YAML$,
  $YAML$correlation:
  confidence_base: 0.92
  match_reason_template: |
    Invoice {{ $signal.metadata.invoice_ref }} for counterparty
    {{ $contract.counterparty.name }} is
    {{ $signal.metadata.days_overdue }} days overdue (AED
    {{ $signal.metadata.amount_aed }}).
alert:
  priority: high
  actions: [recommend_payment_hold, escalate_to_treasury]
$YAML$,
  md5('rule.payment.delay_detect' || 'v1'),
  'demo',
  NOW(),
  NULL,
  NOW(),
  NULL,
  TRUE
WHERE NOT EXISTS (
  SELECT 1 FROM correlation_rule
  WHERE rule_id = 'rule.payment.delay_detect'
    AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
);

-- 2. Seed 3 osint_signal rows, branch-portable — pick first 3 eligible contracts.
--    Each row is keyed by contract_number so the dedup_hash is stable per branch.
--    NOTE: column 'category' is restricted by impact_signal_category_check
--    to (regulatory|commodity_prices|supply_chain|geopolitical|market_financial).
--    'internal' is the new vocabulary on `kind` (TEXT), NOT on legacy `category`.
WITH eligible_contracts AS (
  SELECT
    co.id AS contract_id,
    co.contract_number,
    co.counterparty_id,
    COALESCE(p.name_en, 'Unknown counterparty') AS counterparty_name,
    ROW_NUMBER() OVER (ORDER BY co.id) AS rn
  FROM contract co
  LEFT JOIN party p ON p.id = co.counterparty_id
  WHERE co.is_active = TRUE
    AND co.status IN ('active', 'fully_signed', 'signed')
    AND co.counterparty_id IS NOT NULL
  ORDER BY co.id
  LIMIT 3
),
seed_inputs AS (
  SELECT
    ec.contract_id,
    ec.contract_number,
    ec.counterparty_id,
    ec.counterparty_name,
    ec.rn,
    CASE ec.rn
      WHEN 1 THEN 32 WHEN 2 THEN 21 WHEN 3 THEN 47 END        AS days_overdue,
    CASE ec.rn
      WHEN 1 THEN '1250000.00' WHEN 2 THEN '540000.00' WHEN 3 THEN '2800000.00' END AS amount_aed,
    CASE ec.rn
      WHEN 1 THEN 'INV-2026-0501' WHEN 2 THEN 'INV-2026-0488' WHEN 3 THEN 'INV-2026-0512' END AS invoice_ref,
    CASE ec.rn
      WHEN 1 THEN 'high' WHEN 2 THEN 'medium' WHEN 3 THEN 'high' END AS severity_band
  FROM eligible_contracts ec
)
INSERT INTO osint_signal (
  ext_id, category, source, severity, title_en, title_ar,
  description_en, description_ar, affected_clause_categories,
  published_date, is_seed, tenant_id, source_id, source_reliability,
  fetched_at, event_date_v2, kind, signal_kind_subtype,
  title, summary, geographies, affected_entities, severity_v2,
  confidence, raw_payload, dedup_hash, metadata, data_classification
)
SELECT
  'osint:internal:pmt-delay-' || si.invoice_ref || '-' || si.contract_id AS ext_id,
  'regulatory',
  'internal:harness',
  si.severity_band,
  'Invoice ' || si.invoice_ref || ' — ' || si.days_overdue || ' days overdue (AED ' || si.amount_aed || ')',
  'الفاتورة ' || si.invoice_ref || ' — متأخرة ' || si.days_overdue || ' يومًا (AED ' || si.amount_aed || ')',
  CASE WHEN si.days_overdue >= 30
       THEN 'Counterparty payment overdue beyond 30-day SLA — Treasury hold recommended.'
       ELSE 'Counterparty payment crossing 14-day overdue trigger — review escalation needed.' END,
  CASE WHEN si.days_overdue >= 30
       THEN 'تأخر سداد الطرف المقابل عن مدة الـ 30 يومًا — يوصى بإيقاف الدفع.'
       ELSE 'تجاوز مهلة الـ 14 يومًا — يلزم تصعيد المراجعة.' END,
  ARRAY['payment_terms']::text[],
  CURRENT_DATE,
  FALSE,
  '00000000-0000-0000-0000-000000000001'::uuid,
  'internal:harness',
  1.0,
  NOW(),
  NOW(),
  'internal',
  'payment_delay',
  'Invoice ' || si.invoice_ref || ' — ' || si.days_overdue || ' days overdue (AED ' || si.amount_aed || ')',
  CASE WHEN si.days_overdue >= 30
       THEN 'Counterparty payment overdue beyond 30-day SLA — Treasury hold recommended.'
       ELSE 'Counterparty payment crossing 14-day overdue trigger — review escalation needed.' END,
  '[]'::jsonb,
  jsonb_build_array(jsonb_build_object(
    'entityType', 'counterparty',
    'identifier', si.counterparty_id::text,
    'name',       si.counterparty_name
  )),
  si.severity_band,
  1.0,
  jsonb_build_object(
    'invoice_ref',  si.invoice_ref,
    'days_overdue', si.days_overdue,
    'amount_aed',   si.amount_aed,
    'contract_id',  si.contract_id::text),
  md5('payment_delay|' || si.invoice_ref || '|' || si.contract_id::text),
  jsonb_build_object(
    'invoice_ref',  si.invoice_ref,
    'days_overdue', si.days_overdue,
    'amount_aed',   si.amount_aed,
    'contract_id',  si.contract_id::text),
  'demo'
FROM seed_inputs si
ON CONFLICT (tenant_id, dedup_hash) DO NOTHING;

-- 3. Seed correlation rows linking each new signal to its target contract.
INSERT INTO correlation (
  tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
  confidence, match_reason, match_evidence, match_geographies,
  match_entities, status, data_classification,
  created_at, created_by, updated_at, updated_by, is_active
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  os.id,
  (os.metadata->>'contract_id')::bigint,
  'rule.payment.delay_detect',
  (SELECT version_hash FROM correlation_rule
    WHERE rule_id='rule.payment.delay_detect'
      AND tenant_id='00000000-0000-0000-0000-000000000001'::uuid),
  0.92,
  'Invoice ' || (os.metadata->>'invoice_ref') ||
    ' is ' || (os.metadata->>'days_overdue') || ' days overdue (AED ' ||
    (os.metadata->>'amount_aed') || '). Counterparty payment SLA breached.',
  jsonb_build_object(
    'invoice_ref',  os.metadata->>'invoice_ref',
    'days_overdue', (os.metadata->>'days_overdue')::integer,
    'amount_aed',   os.metadata->>'amount_aed'),
  '[]'::jsonb,
  os.affected_entities,
  'active',
  'demo',
  NOW(),
  NULL,
  NOW(),
  NULL,
  TRUE
FROM osint_signal os
WHERE os.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND os.kind = 'internal'
  AND os.signal_kind_subtype = 'payment_delay'
  AND os.source_id = 'internal:harness'
  AND os.ext_id LIKE 'osint:internal:pmt-delay-INV-2026-%'
  AND EXISTS (SELECT 1 FROM contract co WHERE co.id = (os.metadata->>'contract_id')::bigint)
  AND NOT EXISTS (
    SELECT 1 FROM correlation c2
    WHERE c2.signal_id = os.id
      AND c2.rule_id = 'rule.payment.delay_detect'
      AND c2.tenant_id = os.tenant_id
  );

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (193, 'Unit-3 R-FT3: seed payment_delay signals + rule + correlations for Payment Delay Register', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM correlation
--   WHERE rule_id = 'rule.payment.delay_detect'
--     AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid;
-- DELETE FROM osint_signal
--   WHERE source_id = 'internal:harness'
--     AND signal_kind_subtype = 'payment_delay'
--     AND ext_id LIKE 'osint:internal:pmt-delay-INV-2026-%';
-- DELETE FROM correlation_rule
--   WHERE rule_id = 'rule.payment.delay_detect'
--     AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid;
-- DELETE FROM schema_migrations WHERE version = 193;
