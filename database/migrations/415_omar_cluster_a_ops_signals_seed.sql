-- Migration: 415_omar_cluster_a_ops_signals_seed.sql
-- Unit: Omar Operations QA Phase 3 — Cluster A (Operations dashboard data seeding)
-- Targets:
--   O1   Operations dashboard ALL ZEROS on default Last 7 days view.
--   O2   Last 30d = Last 90d identical (no spread across the window).
--   O6   Penalty exposure chart: 1 bar only.
--   O7   Vendor scorecard: 1 vendor only.
--   O39  Demo-state hygiene — default 7d window must show something.
--
-- What this seeds (last 7 days, across 8 contracts × 8 counterparties):
--   - 8 sla_breach osint_signals + correlations (rule.sla.day_rate_breach)
--   - 4 milestone_slippage signals (rule.epc.cure_notice_pattern reused)
--   - 2 vendor_incident signals (rule.weather.fm_eligible reused)
--   - 1 ics_incident signal (rule.hormuz.charter_party_disruption reused)
--   - Each signal gets risk_score MV refresh so MaR carries
--
-- Idempotent via dedup_hash. Re-applies cleanly.

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_sla_rule_id   TEXT := 'rule.sla.day_rate_breach';
  v_milestone_rid TEXT := 'rule.epc.cure_notice_pattern';
  v_vendor_rid    TEXT := 'rule.weather.fm_eligible';
  v_ics_rid       TEXT := 'rule.hormuz.charter_party_disruption';
  v_sla_rule_hash TEXT;
  v_milestone_hash TEXT;
  v_vendor_hash    TEXT;
  v_ics_hash       TEXT;
BEGIN
  ----------------------------------------------------------------------------
  -- Seed rule.sla.day_rate_breach (new) — needed for sla_breach correlations.
  ----------------------------------------------------------------------------
  INSERT INTO correlation_rule (
    tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
    match_yaml, produce_yaml, version_hash, data_classification,
    created_at, created_by, updated_at, updated_by, is_active
  )
  VALUES (
    v_tenant,
    v_sla_rule_id,
    'Detect day-rate billing exceeding contractual ceiling',
    'كشف تجاوز معدّل اليوم للسقف التعاقدي',
    'operations',
    TRUE,
    jsonb_build_object('threshold_pct', 100, 'category', 'sla_breach'),
    'signal:\n  kind: [internal]\n  signal_kind_subtype: sla_breach\n',
    'correlation:\n  confidence_base: 0.95\nalert:\n  priority: high\n  actions: [draft_cure_notice, escalate_operations]\n',
    md5(v_sla_rule_id || 'v1'),
    'demo',
    NOW(), NULL, NOW(), NULL, TRUE
  )
  ON CONFLICT DO NOTHING;

  SELECT version_hash INTO v_sla_rule_hash    FROM correlation_rule WHERE rule_id = v_sla_rule_id   AND tenant_id = v_tenant;
  SELECT version_hash INTO v_milestone_hash   FROM correlation_rule WHERE rule_id = v_milestone_rid AND tenant_id = v_tenant;
  SELECT version_hash INTO v_vendor_hash      FROM correlation_rule WHERE rule_id = v_vendor_rid    AND tenant_id = v_tenant;
  SELECT version_hash INTO v_ics_hash         FROM correlation_rule WHERE rule_id = v_ics_rid       AND tenant_id = v_tenant;

  ----------------------------------------------------------------------------
  -- Pick 14 distinct demo contracts spanning EPC + Services for the seed
  -- so the penalty chart + vendor scorecard show breadth (O6/O7). Filter
  -- to those WITH counterparty so vendor scorecard joins succeed.
  ----------------------------------------------------------------------------
  CREATE TEMP TABLE _ops_seed_targets AS
  WITH eligible AS (
    SELECT
      c.id AS contract_id,
      c.contract_number,
      c.counterparty_id,
      p.name_en AS counterparty_name,
      c.value_aed,
      c.contract_type,
      ROW_NUMBER() OVER (ORDER BY c.value_aed DESC NULLS LAST, c.id) AS rn
    FROM contract c
    JOIN party p ON p.id = c.counterparty_id
    WHERE c.is_active = TRUE
      AND c.status IN ('active','signed','fully_signed')
      AND c.contract_type IN ('epc','services','gas_spa')
      AND c.value_aed IS NOT NULL
      AND c.value_aed > 1000000
  )
  SELECT * FROM eligible WHERE rn <= 14;

  ----------------------------------------------------------------------------
  -- 8 sla_breach signals + 8 correlations, dates spread across last 7 days
  ----------------------------------------------------------------------------
  WITH sla_inputs AS (
    SELECT
      t.contract_id, t.contract_number, t.counterparty_id, t.counterparty_name, t.value_aed,
      t.rn,
      -- spread across last 7 days
      (NOW() - ((t.rn - 1) || ' days')::interval - INTERVAL '4 hours')::timestamp AS occurred_at,
      CASE WHEN (t.rn % 3) = 0 THEN 'critical' WHEN (t.rn % 2) = 0 THEN 'high' ELSE 'medium' END AS sev,
      -- penalty exposure capped at 5% of contract value, min 500K, max 25M
      LEAST(GREATEST(t.value_aed * 0.0025, 500000)::numeric, 25000000)::numeric AS mar_aed,
      'INV-OPS-SLA-' || LPAD(t.rn::TEXT, 4, '0') AS ref
    FROM _ops_seed_targets t
    WHERE t.rn <= 8
  )
  INSERT INTO osint_signal (
    ext_id, category, source, severity, title_en, title_ar,
    description_en, description_ar, affected_clause_categories,
    published_date, is_seed, tenant_id, source_id, source_reliability,
    fetched_at, event_date_v2, kind, signal_kind_subtype,
    title, summary, geographies, affected_entities, severity_v2,
    confidence, raw_payload, dedup_hash, metadata, data_classification,
    created_at, updated_at, is_active
  )
  SELECT
    'osint:internal:omar-sla-' || si.ref,
    'regulatory',
    'internal:harness',
    si.sev,
    'Day-rate billing exceeded ceiling — ' || si.contract_number,
    'تجاوز معدّل اليوم للسقف — ' || si.contract_number,
    'Counterparty ' || si.counterparty_name || ' exceeded day-rate ceiling. AED ' || si.mar_aed::text || ' SLA penalty exposure.',
    'تجاوز ' || si.counterparty_name || ' السقف اليومي. التعرض للغرامة AED ' || si.mar_aed::text || '.',
    ARRAY['liquidated_damages','service_levels']::text[],
    si.occurred_at::date,
    FALSE,
    v_tenant,
    'internal:harness',
    1.0,
    si.occurred_at,
    si.occurred_at,
    'internal',
    'sla_breach',
    'Day-rate billing exceeded ceiling — ' || si.contract_number,
    'Operations SLA breach signal — day-rate exceeded contractual ceiling.',
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object(
      'entityType', 'counterparty',
      'identifier', si.counterparty_id::text,
      'name',       si.counterparty_name
    )),
    si.sev,
    1.0,
    jsonb_build_object(
      'contract_id',  si.contract_id::text,
      'mar_aed',      si.mar_aed::text,
      'overrun_pct',  '125'),
    md5('omar_sla_breach|' || si.ref || '|' || si.contract_id::text),
    jsonb_build_object(
      'contract_id',     si.contract_id::text,
      'mar_aed',         si.mar_aed::text,
      'milestone_label', 'Q2 day-rate ceiling breached by 11d'),
    'demo',
    si.occurred_at,
    si.occurred_at,
    TRUE
  FROM sla_inputs si
  ON CONFLICT (tenant_id, dedup_hash) DO NOTHING;

  ----------------------------------------------------------------------------
  -- 4 milestone_slippage signals — across days 2..5
  ----------------------------------------------------------------------------
  WITH ms_inputs AS (
    SELECT
      t.contract_id, t.contract_number, t.counterparty_id, t.counterparty_name, t.value_aed, t.rn,
      (NOW() - (((t.rn - 8)) || ' days')::interval - INTERVAL '8 hours')::timestamp AS occurred_at,
      CASE WHEN (t.rn % 2) = 0 THEN 'high' ELSE 'medium' END AS sev,
      LEAST(GREATEST(t.value_aed * 0.002, 350000)::numeric, 18000000)::numeric AS mar_aed,
      'MS-' || LPAD(t.rn::TEXT, 4, '0') AS ref
    FROM _ops_seed_targets t
    WHERE t.rn BETWEEN 9 AND 12
  )
  INSERT INTO osint_signal (
    ext_id, category, source, severity, title_en, title_ar,
    description_en, description_ar, affected_clause_categories,
    published_date, is_seed, tenant_id, source_id, source_reliability,
    fetched_at, event_date_v2, kind, signal_kind_subtype,
    title, summary, geographies, affected_entities, severity_v2,
    confidence, raw_payload, dedup_hash, metadata, data_classification,
    created_at, updated_at, is_active
  )
  SELECT
    'osint:internal:omar-ms-' || ms.ref,
    'regulatory',
    'internal:harness',
    ms.sev,
    'EPC milestone slipped — ' || ms.contract_number,
    'تأخر معلم EPC — ' || ms.contract_number,
    'Construction milestone missed by 11+ days. Cure-notice window opens.',
    'فاتته معلم البناء بأكثر من 11 يومًا. تنفتح نافذة إشعار العلاج.',
    ARRAY['cure_period','milestones']::text[],
    ms.occurred_at::date,
    FALSE,
    v_tenant,
    'internal:harness',
    1.0,
    ms.occurred_at,
    ms.occurred_at,
    'internal',
    'milestone_slippage',
    'EPC milestone slipped — ' || ms.contract_number,
    'EPC mid-FY milestone slipped past planned window.',
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object(
      'entityType', 'counterparty',
      'identifier', ms.counterparty_id::text,
      'name',       ms.counterparty_name
    )),
    ms.sev,
    1.0,
    jsonb_build_object(
      'contract_id',  ms.contract_id::text,
      'mar_aed',      ms.mar_aed::text,
      'days_late',    '11'),
    md5('omar_milestone_slip|' || ms.ref || '|' || ms.contract_id::text),
    jsonb_build_object(
      'contract_id',     ms.contract_id::text,
      'mar_aed',         ms.mar_aed::text,
      'milestone_label', 'Construction Q2 milestone — 11d late'),
    'demo',
    ms.occurred_at,
    ms.occurred_at,
    TRUE
  FROM ms_inputs ms
  ON CONFLICT (tenant_id, dedup_hash) DO NOTHING;

  ----------------------------------------------------------------------------
  -- 2 vendor_incident signals (HSE incidents) on contracts 13/14
  ----------------------------------------------------------------------------
  WITH vi_inputs AS (
    SELECT t.contract_id, t.contract_number, t.counterparty_id, t.counterparty_name, t.value_aed, t.rn,
           (NOW() - ((t.rn - 13) || ' days')::interval - INTERVAL '12 hours')::timestamp AS occurred_at,
           'high' AS sev,
           LEAST(GREATEST(t.value_aed * 0.001, 250000)::numeric, 9000000)::numeric AS mar_aed,
           'VI-' || LPAD(t.rn::TEXT, 4, '0') AS ref
      FROM _ops_seed_targets t
     WHERE t.rn BETWEEN 13 AND 14
  )
  INSERT INTO osint_signal (
    ext_id, category, source, severity, title_en, title_ar,
    description_en, description_ar, affected_clause_categories,
    published_date, is_seed, tenant_id, source_id, source_reliability,
    fetched_at, event_date_v2, kind, signal_kind_subtype,
    title, summary, geographies, affected_entities, severity_v2,
    confidence, raw_payload, dedup_hash, metadata, data_classification,
    created_at, updated_at, is_active
  )
  SELECT
    'osint:internal:omar-vi-' || vi.ref,
    'regulatory',
    'internal:harness',
    vi.sev,
    'HSE incident reported — ' || vi.contract_number,
    'حادث الصحة والسلامة والبيئة — ' || vi.contract_number,
    'Vendor HSE incident affecting field operations. Investigation underway.',
    'حادث الصحة والسلامة والبيئة من المورد يؤثر على العمليات الميدانية.',
    ARRAY['hse','operations']::text[],
    vi.occurred_at::date,
    FALSE,
    v_tenant,
    'internal:harness',
    1.0,
    vi.occurred_at,
    vi.occurred_at,
    'internal',
    'vendor_incident',
    'HSE incident reported — ' || vi.contract_number,
    'Vendor field HSE incident — operations impact.',
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object(
      'entityType', 'counterparty',
      'identifier', vi.counterparty_id::text,
      'name',       vi.counterparty_name
    )),
    vi.sev,
    1.0,
    jsonb_build_object('contract_id', vi.contract_id::text, 'mar_aed', vi.mar_aed::text),
    md5('omar_vendor_incident|' || vi.ref || '|' || vi.contract_id::text),
    jsonb_build_object(
      'contract_id', vi.contract_id::text,
      'mar_aed',     vi.mar_aed::text,
      'milestone_label', 'Reported HSE event 0d ago'),
    'demo',
    vi.occurred_at, vi.occurred_at, TRUE
  FROM vi_inputs vi
  ON CONFLICT (tenant_id, dedup_hash) DO NOTHING;

  ----------------------------------------------------------------------------
  -- 1 ics_incident signal — Hormuz routing disruption (Story 2 cross-cut)
  ----------------------------------------------------------------------------
  INSERT INTO osint_signal (
    ext_id, category, source, severity, title_en, title_ar,
    description_en, description_ar, affected_clause_categories,
    published_date, is_seed, tenant_id, source_id, source_reliability,
    fetched_at, event_date_v2, kind, signal_kind_subtype,
    title, summary, geographies, affected_entities, severity_v2,
    confidence, raw_payload, dedup_hash, metadata, data_classification,
    created_at, updated_at, is_active
  )
  SELECT
    'osint:internal:omar-ics-001',
    'regulatory',
    'internal:harness',
    'critical',
    'Hormuz Strait routing disruption — vessel transit hold',
    'تعطل في مضيق هرمز — تعليق عبور السفينة',
    'ICS incident — vessel transit through Hormuz held due to security alert. Affects active charter party contract.',
    'حادث في النظام التشغيلي — تعليق عبور السفينة عبر مضيق هرمز بسبب تنبيه أمني.',
    ARRAY['force_majeure','routing']::text[],
    (NOW() - INTERVAL '2 days')::date,
    FALSE,
    v_tenant,
    'internal:harness',
    1.0,
    NOW() - INTERVAL '2 days',
    NOW() - INTERVAL '2 days',
    'internal',
    'ics_incident',
    'Hormuz Strait routing disruption — vessel transit hold',
    'ICS incident — Story 2 cross-cut (vessel routing).',
    '[{"identifier":"AE-HRMZ","entityType":"region"}]'::jsonb,
    jsonb_build_array(jsonb_build_object(
      'entityType', 'counterparty',
      'identifier', (SELECT counterparty_id::text FROM _ops_seed_targets WHERE rn = 1 LIMIT 1),
      'name',       (SELECT counterparty_name FROM _ops_seed_targets WHERE rn = 1 LIMIT 1)
    )),
    'critical', 1.0,
    jsonb_build_object('contract_id', (SELECT contract_id FROM _ops_seed_targets WHERE rn = 1 LIMIT 1), 'mar_aed', '4500000'),
    md5('omar_ics_hormuz|001'),
    jsonb_build_object(
      'contract_id', (SELECT contract_id FROM _ops_seed_targets WHERE rn = 1 LIMIT 1),
      'mar_aed', '4500000',
      'milestone_label', 'Hormuz vessel transit hold — Story 2 cross-cut'),
    'demo',
    NOW() - INTERVAL '2 days', NOW() - INTERVAL '2 days', TRUE
  ON CONFLICT (tenant_id, dedup_hash) DO NOTHING;

  ----------------------------------------------------------------------------
  -- Correlations: one per signal, pointing rule_id + linking to contract_id.
  -- Uses os.metadata->>'contract_id' as join key (mirrors pattern from mig 193).
  ----------------------------------------------------------------------------
  INSERT INTO correlation (
    tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
    confidence, match_reason, match_evidence, match_geographies,
    match_entities, status, data_classification,
    created_at, created_by, updated_at, updated_by, is_active
  )
  SELECT
    v_tenant,
    os.id,
    (os.metadata->>'contract_id')::bigint,
    CASE os.signal_kind_subtype
      WHEN 'sla_breach' THEN v_sla_rule_id
      WHEN 'milestone_slippage' THEN v_milestone_rid
      WHEN 'vendor_incident' THEN v_vendor_rid
      WHEN 'ics_incident' THEN v_ics_rid
    END,
    CASE os.signal_kind_subtype
      WHEN 'sla_breach' THEN v_sla_rule_hash
      WHEN 'milestone_slippage' THEN v_milestone_hash
      WHEN 'vendor_incident' THEN v_vendor_hash
      WHEN 'ics_incident' THEN v_ics_hash
    END,
    0.95,
    CASE os.signal_kind_subtype
      WHEN 'sla_breach' THEN 'Day-rate billing exceeded contractual ceiling by 25.8%. AED ' || (os.metadata->>'mar_aed') || ' SLA penalty exposure.'
      WHEN 'milestone_slippage' THEN 'EPC milestone slipped — cure-notice window opens. AED ' || (os.metadata->>'mar_aed') || ' exposure.'
      WHEN 'vendor_incident' THEN 'Vendor HSE incident reported in last 7 days. AED ' || (os.metadata->>'mar_aed') || ' operations exposure.'
      WHEN 'ics_incident' THEN 'Hormuz Strait routing disruption — vessel transit hold. AED ' || (os.metadata->>'mar_aed') || ' Story 2 cross-cut.'
    END,
    jsonb_build_object('mar_aed', os.metadata->>'mar_aed', 'milestone_label', os.metadata->>'milestone_label'),
    '[]'::jsonb,
    os.affected_entities,
    'active',
    'demo',
    os.created_at, NULL, os.created_at, NULL, TRUE
  FROM osint_signal os
  WHERE os.tenant_id = v_tenant
    AND os.kind = 'internal'
    AND os.signal_kind_subtype IN ('sla_breach','milestone_slippage','vendor_incident','ics_incident')
    AND os.source_id = 'internal:harness'
    AND os.ext_id LIKE 'osint:internal:omar-%'
    AND EXISTS (SELECT 1 FROM contract co WHERE co.id = (os.metadata->>'contract_id')::bigint)
    AND NOT EXISTS (
      SELECT 1 FROM correlation c2
       WHERE c2.signal_id = os.id
         AND c2.tenant_id = v_tenant
    );

  ----------------------------------------------------------------------------
  -- Refresh latest_risk_score MV so vendor scorecard tier readings update
  ----------------------------------------------------------------------------
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY latest_risk_score;
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        REFRESH MATERIALIZED VIEW latest_risk_score;
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'mig 415: latest_risk_score MV refresh skipped (% %)', SQLERRM, SQLSTATE;
      END;
  END;

  DROP TABLE IF EXISTS _ops_seed_targets;
  RAISE NOTICE 'mig 415: ops signals + correlations seeded.';
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (415, '415_omar_cluster_a_ops_signals_seed — O1/O2/O6/O7/O39 ops dashboard data', NOW())
ON CONFLICT (version) DO NOTHING;

-- ROLLBACK:
-- DELETE FROM correlation WHERE rule_id IN ('rule.sla.day_rate_breach') AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid;
-- DELETE FROM osint_signal WHERE ext_id LIKE 'osint:internal:omar-%' AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid;
-- DELETE FROM correlation_rule WHERE rule_id = 'rule.sla.day_rate_breach' AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid;
-- DELETE FROM schema_migrations WHERE version = 415;
