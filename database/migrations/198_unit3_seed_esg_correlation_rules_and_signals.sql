-- Migration: 198_unit3_seed_esg_correlation_rules_and_signals.sql
-- Unit: Unit-3 (R-CES — ESG Correlations real content)
-- Description: Seed 3 correlation_rule rows under the rule.esg.* namespace
--              (icv_downgrade / sub_contractor_violation / high_emissions_supplier)
--              + 3 osint_signal rows + at least 1 correlation linking them to
--              real contracts so fn_dashboard_compliance_esg esgCorrelations
--              key returns non-empty results.
--
--              Branch-portable: uses first eligible active contract via CTE
--              rather than hardcoding contract IDs.
--
--              version_hash uses md5(rule_id || 'v1') matching the project
--              pattern from migration 193.
-- Reference: decisions AD-3, GAP-REPORT-COMPLIANCE-ESG H6, R-CES7 round.
-- Rollback: see ROLLBACK section.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- 1. Seed 3 rule.esg.* rows
INSERT INTO correlation_rule (
  tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
  match_yaml, produce_yaml, version_hash, data_classification,
  created_at, created_by, updated_at, updated_by, is_active
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  v.rule_id, v.name, v.name_ar, 'esg', TRUE, v.meta,
  v.match_yaml, v.produce_yaml, md5(v.rule_id || 'v1'), 'demo',
  NOW(), NULL, NOW(), NULL, TRUE
FROM (
  VALUES
    (
      'rule.esg.icv_downgrade',
      'ICV status downgrade for a counterparty',
      'تدني حالة القيمة المضافة الإماراتية للطرف المقابل',
      jsonb_build_object('category','esg','severity_band','high'),
      $YAML$signal:
  kind: [esg, regulatory]
  raw_field: { path: icv_status_new, in: [downgraded, suspended] }
contract:
  status: [active, fully_signed, signed]
  has_counterparty: true
joins:
  entity_match: signal.party_id == contract.counterparty_id
$YAML$,
      $YAML$correlation:
  confidence_base: 0.90
  match_reason_template: |
    Counterparty {{ $contract.counterparty.name }} has had its ICV status
    downgraded ({{ $signal.raw_payload.icv_status_old }} →
    {{ $signal.raw_payload.icv_status_new }}). Review ADNOC ICV requirements.
alert:
  priority: high
  actions: [recommend_icv_review, escalate_to_compliance]
$YAML$
    ),
    (
      'rule.esg.sub_contractor_violation',
      'Sub-contractor sanctions or ESG event in counterparty graph',
      'حدث عقوبات أو ESG عند مقاول من الباطن في شبكة الطرف المقابل',
      jsonb_build_object('category','esg','severity_band','critical'),
      $YAML$signal:
  kind: [sanctions, esg]
  affected_entity_in_graph: true
contract:
  status: [active]
  counterparty_id_in_graph_descendants: true
joins:
  graph_traversal: party_chain_traverse_down
$YAML$,
      $YAML$correlation:
  confidence_base: 0.85
  match_reason_template: |
    A sub-contractor in {{ $contract.counterparty.name }}'s chain
    (entity {{ $match.entity.name }} at depth {{ $match.depth }}) has a
    sanctions or ESG violation. Review chain compliance.
alert:
  priority: critical
  actions: [flag_chain_node, recommend_hold, escalate_to_procurement]
$YAML$
    ),
    (
      'rule.esg.high_emissions_supplier',
      'High-emissions supplier flagged in ESG advisory',
      'مورد ذو انبعاثات عالية مُعلَّم في تنبيه ESG',
      jsonb_build_object('category','esg','severity_band','medium'),
      $YAML$signal:
  kind: [esg]
  raw_field: { path: emissions_band, in: [high, very_high] }
contract:
  status: [active]
  has_counterparty: true
joins:
  entity_match: signal.party_id == contract.counterparty_id
$YAML$,
      $YAML$correlation:
  confidence_base: 0.70
  match_reason_template: |
    Counterparty {{ $contract.counterparty.name }} flagged as
    {{ $signal.raw_payload.emissions_band }} emissions in ESG advisory.
    Advisory-only.
alert:
  priority: medium
  actions: [advisory_review]
$YAML$
    )
) AS v(rule_id, name, name_ar, meta, match_yaml, produce_yaml)
WHERE NOT EXISTS (
  SELECT 1 FROM correlation_rule cr
  WHERE cr.rule_id = v.rule_id
    AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
);

-- 2. Seed 3 osint_signal rows + correlations against the first eligible
--    counterparty contract on this branch. Branch-portable.
WITH target_contracts AS (
  SELECT co.id AS contract_id, co.contract_number, co.counterparty_id,
         COALESCE(p.name_en, 'Unknown counterparty') AS counterparty_name,
         ROW_NUMBER() OVER (ORDER BY co.id) AS rn
  FROM contract co
  LEFT JOIN party p ON p.id = co.counterparty_id
  WHERE co.is_active = TRUE
    AND co.counterparty_id IS NOT NULL
    AND co.status IN ('active','fully_signed','signed')
  ORDER BY co.id
  LIMIT 3
),
seed_signals AS (
  SELECT
    tc.contract_id,
    tc.contract_number,
    tc.counterparty_id,
    tc.counterparty_name,
    tc.rn,
    CASE tc.rn
      WHEN 1 THEN 'rule.esg.icv_downgrade'
      WHEN 2 THEN 'rule.esg.sub_contractor_violation'
      WHEN 3 THEN 'rule.esg.high_emissions_supplier'
    END AS rule_id,
    CASE tc.rn
      WHEN 1 THEN 'high' WHEN 2 THEN 'critical' WHEN 3 THEN 'medium'
    END AS severity_band,
    CASE tc.rn
      WHEN 1 THEN 'esg' WHEN 2 THEN 'sanctions' WHEN 3 THEN 'esg'
    END AS signal_kind,
    CASE tc.rn
      WHEN 1 THEN 'ICV status downgraded for counterparty'
      WHEN 2 THEN 'Sub-contractor sanctions event in counterparty graph'
      WHEN 3 THEN 'High-emissions supplier flagged'
    END AS title_en,
    CASE tc.rn
      WHEN 1 THEN 'تدني حالة ICV للطرف المقابل'
      WHEN 2 THEN 'حدث عقوبات لمقاول من الباطن في الشبكة'
      WHEN 3 THEN 'مورد ذو انبعاثات عالية'
    END AS title_ar,
    CASE tc.rn
      WHEN 1 THEN jsonb_build_object('icv_status_old','silver','icv_status_new','downgraded','reason','contract_violation','party_id',tc.counterparty_id::text)
      WHEN 2 THEN jsonb_build_object('sanctions_source','OFAC SDN','entity_name','Synthetic Holdings Cyprus Ltd','depth',2,'party_id',tc.counterparty_id::text)
      WHEN 3 THEN jsonb_build_object('emissions_band','high','reporting_year',2025,'party_id',tc.counterparty_id::text)
    END AS raw_payload
  FROM target_contracts tc
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
  'osint:esg:' || ss.rule_id || ':' || ss.contract_id AS ext_id,
  'regulatory',
  'internal:harness',
  ss.severity_band,
  ss.title_en,
  ss.title_ar,
  ss.title_en || ' for ' || ss.counterparty_name || '. See contract ' || ss.contract_number || '.',
  ss.title_ar || ' للطرف ' || ss.counterparty_name || '. راجع العقد ' || ss.contract_number || '.',
  ARRAY['esg']::text[],
  CURRENT_DATE,
  FALSE,
  '00000000-0000-0000-0000-000000000001'::uuid,
  'internal:harness',
  0.85,
  NOW(),
  NOW(),
  ss.signal_kind,
  'esg_advisory',
  ss.title_en,
  ss.title_en,
  '[]'::jsonb,
  jsonb_build_array(jsonb_build_object(
    'entityType', 'counterparty',
    'identifier', ss.counterparty_id::text,
    'name',       ss.counterparty_name
  )),
  ss.severity_band,
  0.85,
  ss.raw_payload,
  md5('esg|' || ss.rule_id || '|' || ss.contract_id::text),
  jsonb_build_object('contract_id', ss.contract_id::text, 'rule_id_target', ss.rule_id),
  'demo'
FROM seed_signals ss
ON CONFLICT (tenant_id, dedup_hash) DO NOTHING;

-- 3. Insert correlations linking each ESG signal to its target contract.
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
  os.metadata->>'rule_id_target',
  (SELECT version_hash FROM correlation_rule
    WHERE rule_id = os.metadata->>'rule_id_target'
      AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid),
  0.85,
  CASE os.metadata->>'rule_id_target'
    WHEN 'rule.esg.icv_downgrade'           THEN 'ICV downgrade for counterparty triggers ESG review.'
    WHEN 'rule.esg.sub_contractor_violation' THEN 'Sub-contractor sanctions event in counterparty graph.'
    WHEN 'rule.esg.high_emissions_supplier'  THEN 'High-emissions supplier flagged in ESG advisory.'
    ELSE 'ESG correlation matched.'
  END,
  os.raw_payload,
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
  AND os.source_id = 'internal:harness'
  AND os.signal_kind_subtype = 'esg_advisory'
  AND os.metadata ? 'contract_id'
  AND os.metadata ? 'rule_id_target'
  AND EXISTS (SELECT 1 FROM contract co WHERE co.id = (os.metadata->>'contract_id')::bigint AND co.is_active = TRUE)
  AND NOT EXISTS (
    SELECT 1 FROM correlation c2
    WHERE c2.signal_id = os.id
      AND c2.rule_id   = os.metadata->>'rule_id_target'
      AND c2.tenant_id = os.tenant_id
  );

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (198, 'Unit-3 R-CES7: seed rule.esg.* rules + signals + correlations for ESG Correlations widget', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM correlation
--   WHERE rule_id LIKE 'rule.esg.%'
--     AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid;
-- DELETE FROM osint_signal
--   WHERE source_id = 'internal:harness'
--     AND signal_kind_subtype = 'esg_advisory';
-- DELETE FROM correlation_rule
--   WHERE rule_id LIKE 'rule.esg.%'
--     AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid;
-- DELETE FROM schema_migrations WHERE version = 198;
