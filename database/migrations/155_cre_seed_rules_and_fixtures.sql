-- Migration: 155_cre_seed_rules_and_fixtures.sql
-- Module: M13 / CR-E — Correlation Rule Engine
-- Description: 7 correlation_rule INSERTs + 14 correlation_rule_fixture INSERTs (Annex C.7 + C.9).
--   version_hash computed at INSERT via pgcrypto encode(digest(..., 'sha256'), 'hex').
--   Fixtures reference correlation_rule_id via subquery on (rule_id, tenant_id).
--   ON CONFLICT DO NOTHING — idempotent.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Set tenant GUC for RLS
DO $$ BEGIN PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', false); END $$;

-- -----------------------------------------------
-- 7 correlation_rule INSERTs (Annex C.7)
-- version_hash = SHA-256(match_yaml || '\n' || produce_yaml || '\n' || meta::text)
-- -----------------------------------------------

-- Rule 1: Hormuz Charter Party Disruption (Annex C.7.1)
INSERT INTO correlation_rule (
  tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
  match_yaml, produce_yaml, version_hash,
  data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'rule.hormuz.charter_party_disruption',
  'Hormuz disruption affects charter party contracts with Strait routing',
  '[AR] Hormuz disruption affects charter party contracts with Strait routing',
  'hormuz', TRUE,
  '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Charter party contracts whose voyage routes pass through the Strait of Hormuz are directly exposed to Hormuz disruption events. This rule surfaces affected contracts with FM clause options for Legal review and route alternatives for Procurement."}'::jsonb,
  $match$signal:
  kind: [geopolitical, logistics]
  geography_intersects: [hormuz_strait, persian_gulf]
  severity_min: medium
  confidence_min: 0.7
contract:
  status: [active]
  contract_type: [charter_party, supply]
  route_intersects: [hormuz_strait]
  has_clause: [force_majeure]$match$,
  $produce$correlation:
  confidence_base: 0.85
  match_reason_template: |
    Charter party {{ $contract.id }} ({{ $contract.title }}) routes through
    {{ $match.geography }}. Signal "{{ $signal.title }}" with severity
    {{ $signal.severity }} indicates disruption affecting voyages in this corridor.
  evidence:
    - signal: $signal.id
    - signal_url: $signal.url
    - clause: $contract.clauses[type=force_majeure].id
alert:
  priority_from: $signal.severity
  assigned_roles: [legal, procurement]
  sla_hours: 4
  dedupe_key: "hormuz:{{ $contract.id }}:{{ $signal.event_date | date }}"
advisory:
  template: hormuz_force_majeure_v1
  recipients: [$contract.counterparty]$produce$,
  encode(digest(
    $match$signal:
  kind: [geopolitical, logistics]
  geography_intersects: [hormuz_strait, persian_gulf]
  severity_min: medium
  confidence_min: 0.7
contract:
  status: [active]
  contract_type: [charter_party, supply]
  route_intersects: [hormuz_strait]
  has_clause: [force_majeure]$match$ || E'\n' ||
    $produce$correlation:
  confidence_base: 0.85
  match_reason_template: |
    Charter party {{ $contract.id }} ({{ $contract.title }}) routes through
    {{ $match.geography }}. Signal "{{ $signal.title }}" with severity
    {{ $signal.severity }} indicates disruption affecting voyages in this corridor.
  evidence:
    - signal: $signal.id
    - signal_url: $signal.url
    - clause: $contract.clauses[type=force_majeure].id
alert:
  priority_from: $signal.severity
  assigned_roles: [legal, procurement]
  sla_hours: 4
  dedupe_key: "hormuz:{{ $contract.id }}:{{ $signal.event_date | date }}"
advisory:
  template: hormuz_force_majeure_v1
  recipients: [$contract.counterparty]$produce$ || E'\n' ||
    '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Charter party contracts whose voyage routes pass through the Strait of Hormuz are directly exposed to Hormuz disruption events. This rule surfaces affected contracts with FM clause options for Legal review and route alternatives for Procurement."}',
    'sha256'
  ), 'hex'),
  'demo', NULL, NULL
ON CONFLICT (tenant_id, rule_id) DO NOTHING;

-- Rule 2: Hormuz Supply Disruption (Annex C.7.1 variant)
INSERT INTO correlation_rule (
  tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
  match_yaml, produce_yaml, version_hash,
  data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'rule.hormuz.supply_disruption',
  'Hormuz disruption affects supply contracts with Gulf-routed deliveries',
  '[AR] Hormuz disruption affects supply contracts with Gulf-routed deliveries',
  'hormuz', TRUE,
  '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Supply contracts with Gulf-routed delivery obligations are exposed to Hormuz disruption at high severity. Lower confidence_base than charter party (less direct route dependency)."}'::jsonb,
  $match2$signal:
  kind: [geopolitical, logistics]
  geography_intersects: [hormuz_strait]
  severity_min: high
contract:
  status: [active]
  contract_type: [supply]
  geography_intersects: [persian_gulf, strait_of_hormuz]
  has_clause: [force_majeure, excusable_delay]$match2$,
  $produce2$correlation:
  confidence_base: 0.80
  match_reason_template: |
    Supply contract {{ $contract.id }} has Gulf-routed delivery obligations
    affected by signal "{{ $signal.title }}".
alert:
  priority: high
  assigned_roles: [legal, operations]
  sla_hours: 4$produce2$,
  encode(digest(
    $match2$signal:
  kind: [geopolitical, logistics]
  geography_intersects: [hormuz_strait]
  severity_min: high
contract:
  status: [active]
  contract_type: [supply]
  geography_intersects: [persian_gulf, strait_of_hormuz]
  has_clause: [force_majeure, excusable_delay]$match2$ || E'\n' ||
    $produce2$correlation:
  confidence_base: 0.80
  match_reason_template: |
    Supply contract {{ $contract.id }} has Gulf-routed delivery obligations
    affected by signal "{{ $signal.title }}".
alert:
  priority: high
  assigned_roles: [legal, operations]
  sla_hours: 4$produce2$ || E'\n' ||
    '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Supply contracts with Gulf-routed delivery obligations are exposed to Hormuz disruption at high severity. Lower confidence_base than charter party (less direct route dependency)."}',
    'sha256'
  ), 'hex'),
  'demo', NULL, NULL
ON CONFLICT (tenant_id, rule_id) DO NOTHING;

-- Rule 3: Sanctions Direct Counterparty (Annex C.7.2)
INSERT INTO correlation_rule (
  tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
  match_yaml, produce_yaml, version_hash,
  data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'rule.sanctions.direct_counterparty',
  'Sanctions designation directly hits a contract counterparty',
  '[AR] Sanctions designation directly hits a contract counterparty',
  'sanctions', TRUE,
  '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Direct hit on counterparty is the highest-confidence sanctions correlation. Triggers immediate Compliance review and Legal hold-notice draft."}'::jsonb,
  $match3$signal:
  kind: [sanctions]
  source_id_in: [ofac_sdn, eu_consolidated, un_security_council, uk_hmt]
  affected_entity_in_graph: true
contract:
  status: [active]
joins:
  entity_match: signal_directly_matches_counterparty$match3$,
  $produce3$correlation:
  confidence_base: 0.98
  match_reason_template: |
    Sanctions designation by {{ $signal.source_id }} directly identifies
    counterparty {{ $contract.counterparty.name }} (entity match:
    {{ $match.entity.name }}).
  evidence:
    - signal: $signal.id
    - sdn_entry: $signal.raw_payload.uid
    - counterparty: $contract.counterparty.id
alert:
  priority: critical
  assigned_roles: [compliance, legal]
  sla_hours: 2
  dedupe_key: "sanctions:direct:{{ $contract.id }}:{{ $signal.source_id }}"
advisory:
  template: sanctions_hold_notice_v1
  recipients: [$contract.counterparty]$produce3$,
  encode(digest(
    $match3$signal:
  kind: [sanctions]
  source_id_in: [ofac_sdn, eu_consolidated, un_security_council, uk_hmt]
  affected_entity_in_graph: true
contract:
  status: [active]
joins:
  entity_match: signal_directly_matches_counterparty$match3$ || E'\n' ||
    $produce3$correlation:
  confidence_base: 0.98
  match_reason_template: |
    Sanctions designation by {{ $signal.source_id }} directly identifies
    counterparty {{ $contract.counterparty.name }} (entity match:
    {{ $match.entity.name }}).
  evidence:
    - signal: $signal.id
    - sdn_entry: $signal.raw_payload.uid
    - counterparty: $contract.counterparty.id
alert:
  priority: critical
  assigned_roles: [compliance, legal]
  sla_hours: 2
  dedupe_key: "sanctions:direct:{{ $contract.id }}:{{ $signal.source_id }}"
advisory:
  template: sanctions_hold_notice_v1
  recipients: [$contract.counterparty]$produce3$ || E'\n' ||
    '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Direct hit on counterparty is the highest-confidence sanctions correlation. Triggers immediate Compliance review and Legal hold-notice draft."}',
    'sha256'
  ), 'hex'),
  'demo', NULL, NULL
ON CONFLICT (tenant_id, rule_id) DO NOTHING;

-- Rule 4: Sanctions Chain Exposure (Annex C.7.2 variant)
INSERT INTO correlation_rule (
  tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
  match_yaml, produce_yaml, version_hash,
  data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'rule.sanctions.chain_exposure',
  'Sanctions designation hits an entity in the counterparty chain',
  '[AR] Sanctions designation hits an entity in the counterparty chain',
  'sanctions', TRUE,
  '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Indirect exposure through corporate hierarchy. Confidence is lower than direct match but action is still required. Chain depth and ownership percentages drive the materiality assessment."}'::jsonb,
  $match4$signal:
  kind: [sanctions]
  source_id_in: [ofac_sdn, eu_consolidated, un_security_council, uk_hmt]
  affected_entity_in_graph: true
contract:
  status: [active]
  counterparty_id_in_graph_descendants_of: $signal.affected_entities[*]$match4$,
  $produce4$correlation:
  confidence_base: 0.75
  match_reason_template: |
    Sanctions designation by {{ $signal.source_id }} of {{ $match.entity.name }}
    ({{ $match.entity.kind }}) reaches counterparty {{ $contract.counterparty.name }}
    via {{ $match.chain_path }}.
alert:
  priority: high
  assigned_roles: [compliance, legal]
  sla_hours: 8$produce4$,
  encode(digest(
    $match4$signal:
  kind: [sanctions]
  source_id_in: [ofac_sdn, eu_consolidated, un_security_council, uk_hmt]
  affected_entity_in_graph: true
contract:
  status: [active]
  counterparty_id_in_graph_descendants_of: $signal.affected_entities[*]$match4$ || E'\n' ||
    $produce4$correlation:
  confidence_base: 0.75
  match_reason_template: |
    Sanctions designation by {{ $signal.source_id }} of {{ $match.entity.name }}
    ({{ $match.entity.kind }}) reaches counterparty {{ $contract.counterparty.name }}
    via {{ $match.chain_path }}.
alert:
  priority: high
  assigned_roles: [compliance, legal]
  sla_hours: 8$produce4$ || E'\n' ||
    '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Indirect exposure through corporate hierarchy. Confidence is lower than direct match but action is still required. Chain depth and ownership percentages drive the materiality assessment."}',
    'sha256'
  ), 'hex'),
  'demo', NULL, NULL
ON CONFLICT (tenant_id, rule_id) DO NOTHING;

-- Rule 5: Brent Price Review Trigger (Annex C.7.3)
INSERT INTO correlation_rule (
  tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
  match_yaml, produce_yaml, version_hash,
  data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'rule.brent.price_review_trigger_high',
  'Brent crosses upward price-review threshold for a supply contract',
  '[AR] Brent crosses upward price-review threshold for a supply contract',
  'brent', TRUE,
  '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Sustained Brent price above contractual threshold triggers the price-review mechanism in supply contracts. The 90-day sustain window avoids firing on transient price spikes."}'::jsonb,
  $match5$signal:
  kind: [commodity]
  source_id: commodity_crude
  raw_field: { path: marker, equals: BRENT }
contract:
  status: [active]
  has_clause: [price_review]
  clause_parameter:
    clause: price_review
    path: trigger_index
    equals: brent
joins:
  index_threshold:
    signal_index: brent
    contract_clause: price_review
    comparator: crosses_threshold_high
    sustain_window_days: 90$match5$,
  $produce5$correlation:
  confidence_base: 0.95
  match_reason_template: |
    Brent price {{ $signal.raw_payload.price }} USD/bbl has crossed the upward
    price-review threshold of
    {{ $contract.clauses[type=price_review].parameters.trigger_threshold_high.amount }}
    USD/bbl in contract {{ $contract.id }} sustained over
    {{ $match.threshold.sustain_window_days }} days.
alert:
  priority: high
  assigned_roles: [legal, finance]
  sla_hours: 24
  dedupe_key: "brent_review:{{ $contract.id }}:high"
advisory:
  template: price_review_invocation_v1
  recipients: [$contract.counterparty]$produce5$,
  encode(digest(
    $match5$signal:
  kind: [commodity]
  source_id: commodity_crude
  raw_field: { path: marker, equals: BRENT }
contract:
  status: [active]
  has_clause: [price_review]
  clause_parameter:
    clause: price_review
    path: trigger_index
    equals: brent
joins:
  index_threshold:
    signal_index: brent
    contract_clause: price_review
    comparator: crosses_threshold_high
    sustain_window_days: 90$match5$ || E'\n' ||
    $produce5$correlation:
  confidence_base: 0.95
  match_reason_template: |
    Brent price {{ $signal.raw_payload.price }} USD/bbl has crossed the upward
    price-review threshold of
    {{ $contract.clauses[type=price_review].parameters.trigger_threshold_high.amount }}
    USD/bbl in contract {{ $contract.id }} sustained over
    {{ $match.threshold.sustain_window_days }} days.
alert:
  priority: high
  assigned_roles: [legal, finance]
  sla_hours: 24
  dedupe_key: "brent_review:{{ $contract.id }}:high"
advisory:
  template: price_review_invocation_v1
  recipients: [$contract.counterparty]$produce5$ || E'\n' ||
    '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Sustained Brent price above contractual threshold triggers the price-review mechanism in supply contracts. The 90-day sustain window avoids firing on transient price spikes."}',
    'sha256'
  ), 'hex'),
  'demo', NULL, NULL
ON CONFLICT (tenant_id, rule_id) DO NOTHING;

-- Rule 6: EPC SLA Cure Notice (Annex C.7.4)
INSERT INTO correlation_rule (
  tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
  match_yaml, produce_yaml, version_hash,
  data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'rule.epc.cure_notice_pattern',
  'Repeated milestone slippage by EPC contractor — cure notice candidate',
  '[AR] Repeated milestone slippage by EPC contractor — cure notice candidate',
  'epc_sla', TRUE,
  '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Repeated milestone slippage is a strong predictor of contractor default. Four or more slippage events in 180 days justifies issuing a cure notice under the SLA/cure-period clause before triggering LDs."}'::jsonb,
  $match6$signal:
  kind: [internal]
  raw_field: { path: signal_type, equals: milestone_slippage }
  raw_field: { path: count_in_180_days, gte: 3 }
contract:
  status: [active]
  contract_type: [epc]
  has_clause: [sla_performance, cure_period, liquidated_damages]$match6$,
  $produce6$correlation:
  confidence_base: 0.90
  match_reason_template: |
    EPC contract {{ $contract.id }} has experienced
    {{ $signal.raw_payload.count_in_180_days }} milestone slippages in 180 days.
    Cure period clause provides
    {{ $contract.clauses[type=cure_period].parameters.cure_period_days }} days notice;
    LD clause provides
    {{ $contract.clauses[type=liquidated_damages].parameters.ld_rate.amount }} per day.
alert:
  priority: high
  assigned_roles: [procurement, legal]
  sla_hours: 24
advisory:
  template: cure_notice_v1
  recipients: [$contract.counterparty]$produce6$,
  encode(digest(
    $match6$signal:
  kind: [internal]
  raw_field: { path: signal_type, equals: milestone_slippage }
  raw_field: { path: count_in_180_days, gte: 3 }
contract:
  status: [active]
  contract_type: [epc]
  has_clause: [sla_performance, cure_period, liquidated_damages]$match6$ || E'\n' ||
    $produce6$correlation:
  confidence_base: 0.90
  match_reason_template: |
    EPC contract {{ $contract.id }} has experienced
    {{ $signal.raw_payload.count_in_180_days }} milestone slippages in 180 days.
    Cure period clause provides
    {{ $contract.clauses[type=cure_period].parameters.cure_period_days }} days notice;
    LD clause provides
    {{ $contract.clauses[type=liquidated_damages].parameters.ld_rate.amount }} per day.
alert:
  priority: high
  assigned_roles: [procurement, legal]
  sla_hours: 24
advisory:
  template: cure_notice_v1
  recipients: [$contract.counterparty]$produce6$ || E'\n' ||
    '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Repeated milestone slippage is a strong predictor of contractor default. Four or more slippage events in 180 days justifies issuing a cure notice under the SLA/cure-period clause before triggering LDs."}',
    'sha256'
  ), 'hex'),
  'demo', NULL, NULL
ON CONFLICT (tenant_id, rule_id) DO NOTHING;

-- Rule 7: Renewal Lookahead (Annex C.7.5)
INSERT INTO correlation_rule (
  tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
  match_yaml, produce_yaml, version_hash,
  data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'rule.renewal.lookahead',
  'Contract renewal approaching — surface for negotiation runway',
  '[AR] Contract renewal approaching — surface for negotiation runway',
  'renewal', TRUE,
  '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Auto-renewal contracts need notice action by a deadline; non-renewable contracts need negotiation runway. This rule fires per contract per lookahead window."}'::jsonb,
  $match7$signal:
  kind: [internal]
  source_id: calendar_timer
contract:
  status: [active]
  has_clause: [term_and_renewal]
  renewal_within_days: 90$match7$,
  $produce7$correlation:
  confidence_base: 1.0
  match_reason_template: |
    Contract {{ $contract.id }} ({{ $contract.title }}) approaches renewal /
    auto-renewal trigger on
    {{ $contract.clauses[type=term_and_renewal].parameters.expiry_date }}.
    Renewal type:
    {{ $contract.clauses[type=term_and_renewal].parameters.renewal_type }}.
alert:
  priority_from: |
    case [days_to_renewal < 30: high, days_to_renewal < 60: medium, else: low]
  assigned_roles: [procurement, legal]
  sla_hours: 168
  dedupe_key: "renewal:{{ $contract.id }}:{{ $now | date }}"$produce7$,
  encode(digest(
    $match7$signal:
  kind: [internal]
  source_id: calendar_timer
contract:
  status: [active]
  has_clause: [term_and_renewal]
  renewal_within_days: 90$match7$ || E'\n' ||
    $produce7$correlation:
  confidence_base: 1.0
  match_reason_template: |
    Contract {{ $contract.id }} ({{ $contract.title }}) approaches renewal /
    auto-renewal trigger on
    {{ $contract.clauses[type=term_and_renewal].parameters.expiry_date }}.
    Renewal type:
    {{ $contract.clauses[type=term_and_renewal].parameters.renewal_type }}.
alert:
  priority_from: |
    case [days_to_renewal < 30: high, days_to_renewal < 60: medium, else: low]
  assigned_roles: [procurement, legal]
  sla_hours: 168
  dedupe_key: "renewal:{{ $contract.id }}:{{ $now | date }}"$produce7$ || E'\n' ||
    '{"owner":"dexian-architect","lastReviewed":"2026-04-15","rationale":"Auto-renewal contracts need notice action by a deadline; non-renewable contracts need negotiation runway. This rule fires per contract per lookahead window."}',
    'sha256'
  ), 'hex'),
  'demo', NULL, NULL
ON CONFLICT (tenant_id, rule_id) DO NOTHING;

-- -----------------------------------------------
-- 14 correlation_rule_fixture INSERTs (Annex C.9)
-- correlation_rule_id resolved via subquery on (rule_id, tenant_id)
-- -----------------------------------------------

-- Fixtures for rule.hormuz.charter_party_disruption
INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_01_match',
  'Hormuz geopolitical news at high severity matches active charter party with Strait route',
  '{"sourceId":"rss_reuters_energy","kind":"geopolitical","severity":"high","confidence":0.9,"title":"Tensions rise in Strait of Hormuz following vessel incident","geographies":[{"namedRegion":"hormuz_strait"}],"affectedEntities":[],"rawPayload":{}}'::jsonb,
  'hormuz_demo_seed', TRUE,
  '{"confidenceMin":0.60,"confidenceMax":0.85,"matchReasonContains":"routes through"}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.hormuz.charter_party_disruption' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_02_no_match',
  'Hormuz news but severity=low — below severity_min:medium threshold. Should NOT fire.',
  '{"sourceId":"rss_reuters_energy","kind":"geopolitical","severity":"low","confidence":0.9,"title":"Minor shipping advisory issued for Persian Gulf approaches","geographies":[{"namedRegion":"hormuz_strait"}],"affectedEntities":[],"rawPayload":{}}'::jsonb,
  'hormuz_demo_seed', FALSE, '{}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.hormuz.charter_party_disruption' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

-- Fixtures for rule.hormuz.supply_disruption
INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_01_match',
  'High-severity Hormuz geopolitical signal matches active supply contract with Gulf routing',
  '{"sourceId":"rss_reuters_energy","kind":"geopolitical","severity":"high","confidence":0.85,"title":"Hormuz Strait transit disrupted — vessels rerouting via Cape of Good Hope","geographies":[{"namedRegion":"hormuz_strait"}],"affectedEntities":[],"rawPayload":{}}'::jsonb,
  'hormuz_demo_seed', TRUE,
  '{"confidenceMin":0.60,"confidenceMax":0.82}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.hormuz.supply_disruption' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_02_no_match',
  'Hormuz signal at medium severity (below high threshold for supply disruption rule). Should NOT fire.',
  '{"sourceId":"rss_reuters_energy","kind":"geopolitical","severity":"medium","confidence":0.8,"title":"Increased naval activity in Strait of Hormuz","geographies":[{"namedRegion":"hormuz_strait"}],"affectedEntities":[],"rawPayload":{}}'::jsonb,
  'hormuz_demo_seed', FALSE, '{}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.hormuz.supply_disruption' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

-- Fixtures for rule.sanctions.direct_counterparty
INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_01_match',
  'OFAC SDN signal directly names active contract counterparty entity',
  '{"sourceId":"ofac_sdn","kind":"sanctions","severity":"critical","confidence":0.98,"title":"OFAC SDN Update: Petrochem Trading LLC added to SDN list","geographies":[],"affectedEntities":[{"id":"test_counterparty_001","kind":"company","name":"Petrochem Trading LLC"}],"rawPayload":{"uid":"SDN-2026-04-15-0042","program":"IRAN"}}'::jsonb,
  'sanctions_demo_seed', TRUE,
  '{"confidenceMin":0.90,"confidenceMax":1.0,"matchReasonContains":"directly identifies"}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.sanctions.direct_counterparty' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_02_no_match',
  'OFAC signal but entity NOT in counterparty graph — no active contracts reference this entity',
  '{"sourceId":"ofac_sdn","kind":"sanctions","severity":"critical","confidence":0.98,"title":"OFAC SDN Update: Unrelated Entity XYZ added to SDN list","geographies":[],"affectedEntities":[{"id":"unknown_entity_9999","kind":"company","name":"Unrelated Entity XYZ"}],"rawPayload":{"uid":"SDN-2026-04-15-0043","program":"IRAN"}}'::jsonb,
  'sanctions_demo_seed', FALSE, '{}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.sanctions.direct_counterparty' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

-- Fixtures for rule.sanctions.chain_exposure
INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_01_match',
  'OFAC signal hits ParentCo which is 2 levels above active counterparty SubCo2 via chain',
  '{"sourceId":"ofac_sdn","kind":"sanctions","severity":"high","confidence":0.95,"title":"OFAC SDN: HoldCo Group Ltd designated — controls SubCo1 → SubCo2","geographies":[],"affectedEntities":[{"id":"test_parent_holdco","kind":"company","name":"HoldCo Group Ltd"}],"rawPayload":{"uid":"SDN-2026-04-15-0051","program":"SDN"}}'::jsonb,
  'sanctions_chain_demo_seed', TRUE,
  '{"confidenceMin":0.60,"confidenceMax":0.76,"matchReasonContains":"reaches counterparty"}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.sanctions.chain_exposure' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_02_no_match',
  'Sanctions signal but affected entity has no descendants in our counterparty graph',
  '{"sourceId":"ofac_sdn","kind":"sanctions","severity":"high","confidence":0.95,"title":"OFAC SDN: Isolated Shell Corp — no known affiliates","geographies":[],"affectedEntities":[{"id":"isolated_shell_corp_4444","kind":"company","name":"Isolated Shell Corp"}],"rawPayload":{"uid":"SDN-2026-04-15-0052","program":"SDN"}}'::jsonb,
  'sanctions_chain_demo_seed', FALSE, '{}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.sanctions.chain_exposure' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

-- Fixtures for rule.brent.price_review_trigger_high
INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_01_match',
  'Brent commodity signal at $97/bbl sustained 91 days; contract threshold $95/bbl → fires',
  '{"sourceId":"commodity_crude","kind":"commodity","severity":"high","confidence":0.99,"title":"Brent crude price: $97.20/bbl (91-day sustained high)","geographies":[],"affectedEntities":[],"rawPayload":{"marker":"BRENT","price":97.20,"sustainDays":91}}'::jsonb,
  'brent_demo_seed', TRUE,
  '{"confidenceMin":0.90,"confidenceMax":0.96,"matchReasonContains":"crossed the upward"}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.brent.price_review_trigger_high' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_02_no_match',
  'Brent at $97 but only 45 days sustained — below 90-day sustain_window. Should NOT fire.',
  '{"sourceId":"commodity_crude","kind":"commodity","severity":"high","confidence":0.99,"title":"Brent crude spike: $97.00/bbl (transient — 45 days)","geographies":[],"affectedEntities":[],"rawPayload":{"marker":"BRENT","price":97.00,"sustainDays":45}}'::jsonb,
  'brent_demo_seed', FALSE, '{}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.brent.price_review_trigger_high' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

-- Fixtures for rule.epc.cure_notice_pattern
INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_01_match',
  '4th milestone_slippage internal signal in 180 days on active EPC contract → cure notice fires',
  '{"sourceId":"internal_milestone_tracker","kind":"internal","severity":"high","confidence":1.0,"title":"Milestone slippage #4 recorded for EPC contract CP-EPC-001","geographies":[],"affectedEntities":[],"rawPayload":{"signal_type":"milestone_slippage","count_in_180_days":4,"contract_id":"CP-EPC-001"}}'::jsonb,
  'epc_demo_seed', TRUE,
  '{"confidenceMin":0.85,"confidenceMax":0.92,"matchReasonContains":"milestone slippages"}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.epc.cure_notice_pattern' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_02_no_match',
  'Only 2 milestone slippages in 180 days (count_in_180_days=2, below gte:3). Should NOT fire.',
  '{"sourceId":"internal_milestone_tracker","kind":"internal","severity":"medium","confidence":1.0,"title":"Milestone slippage #2 recorded for EPC contract CP-EPC-001","geographies":[],"affectedEntities":[],"rawPayload":{"signal_type":"milestone_slippage","count_in_180_days":2,"contract_id":"CP-EPC-001"}}'::jsonb,
  'epc_demo_seed', FALSE, '{}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.epc.cure_notice_pattern' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

-- Fixtures for rule.renewal.lookahead
INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_01_match',
  'Calendar timer signal; contract expires in 60 days → renewal correlation fires with priority=medium',
  '{"sourceId":"calendar_timer","kind":"internal","severity":"low","confidence":1.0,"title":"Daily renewal lookahead check — 2026-05-12","geographies":[],"affectedEntities":[],"rawPayload":{"run_date":"2026-05-12"}}'::jsonb,
  'renewal_demo_seed', TRUE,
  '{"confidenceMin":0.95,"confidenceMax":1.0,"matchReasonContains":"approaches renewal"}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.renewal.lookahead' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

INSERT INTO correlation_rule_fixture (tenant_id, correlation_rule_id, fixture_id, description, given_signal, given_contract_seed_set, expected_match, expected_correlation, data_classification)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, cr.id,
  'case_02_no_match',
  'Calendar timer; contract expires in 180 days — outside 90-day renewal_within_days window. Should NOT fire.',
  '{"sourceId":"calendar_timer","kind":"internal","severity":"low","confidence":1.0,"title":"Daily renewal lookahead check — 2026-05-12","geographies":[],"affectedEntities":[],"rawPayload":{"run_date":"2026-05-12"}}'::jsonb,
  'renewal_far_demo_seed', FALSE, '{}'::jsonb, 'demo'
FROM correlation_rule cr WHERE cr.rule_id = 'rule.renewal.lookahead' AND cr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (155, '155_cre_seed_rules_and_fixtures', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 155;
-- DELETE FROM correlation_rule_fixture
--   WHERE correlation_rule_id IN (SELECT id FROM correlation_rule WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid AND rule_id IN ('rule.hormuz.charter_party_disruption','rule.hormuz.supply_disruption','rule.sanctions.direct_counterparty','rule.sanctions.chain_exposure','rule.brent.price_review_trigger_high','rule.epc.cure_notice_pattern','rule.renewal.lookahead'));
-- DELETE FROM correlation_rule WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid AND rule_id IN ('rule.hormuz.charter_party_disruption','rule.hormuz.supply_disruption','rule.sanctions.direct_counterparty','rule.sanctions.chain_exposure','rule.brent.price_review_trigger_high','rule.epc.cure_notice_pattern','rule.renewal.lookahead');
-- ============================================================
