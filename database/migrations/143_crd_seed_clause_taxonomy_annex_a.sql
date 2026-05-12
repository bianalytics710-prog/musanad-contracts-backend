-- Migration: 143_crd_seed_clause_taxonomy_annex_a.sql
-- Module: M12 / CR-D — Clause Taxonomy Seed
-- Description: 50-row INSERT for clause_taxonomy from Annex A.3..A.10 + A.11. ADNOC tenant only.
-- Source: seed-data.ts seedClauseTaxonomy array (50 rows, authoritative)
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Seed marker tag: 'annex_a_v1' — used in rollback DELETE
-- Set tenant GUC for RLS + insertion context
DO $$ BEGIN PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', false); END $$;

-- ---- FAMILY: force_majeure (A.3) ---- 8 rows ----

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'force_majeure', 'force_majeure',
  'Force Majeure', '[AR] Force Majeure',
  'A clause that excuses non-performance, delays performance, or extends time when defined extraordinary circumstances occur.',
  '[AR] A clause that excuses non-performance, delays performance, or extends time when defined extraordinary circumstances occur.',
  'Section headings containing "force majeure" or "FM"; phrases like "shall not be liable", "excused from performance", "beyond reasonable control".',
  '[AR] Section headings containing "force majeure" or "FM"; phrases like "shall not be liable", "excused from performance", "beyond reasonable control".',
  '{"triggering_events":{"type":"enum_list","required":false,"enum_values":["war","terrorism","embargo","strike","lockout","epidemic","pandemic","natural_disaster","fire","flood","port_closure","government_action","sanctions","sabotage","other"]},"notice_period_days":{"type":"duration_days","required":false},"notice_addressee":{"type":"party_ref","required":false},"notice_method":{"type":"enum_list","required":false,"enum_values":["registered_post","courier","email","hand_delivery"]},"documentation_requirement":{"type":"text_excerpt","required":false},"relief_type":{"type":"enum","required":false,"enum_values":["extension_of_time","suspension","excuse_from_liability","termination_after_extended_fm"]},"max_fm_duration_days":{"type":"duration_days","required":false},"excluded_events":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'hardship', 'force_majeure',
  'Hardship', '[AR] Hardship',
  'A clause permitting renegotiation or relief when performance becomes commercially unreasonable but is still technically possible (distinct from FM).',
  '[AR] A clause permitting renegotiation or relief when performance becomes commercially unreasonable but is still technically possible (distinct from FM).',
  '"hardship", "material adverse change", "economic equilibrium", "renegotiation".',
  '[AR] "hardship", "material adverse change", "economic equilibrium", "renegotiation".',
  '{"triggering_threshold":{"type":"text_excerpt","required":false},"renegotiation_period_days":{"type":"duration_days","required":false},"fallback_remedy":{"type":"enum","required":false,"enum_values":["arbitration","termination","continue_unchanged"]}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'excusable_delay', 'force_majeure',
  'Excusable Delay', '[AR] Excusable Delay',
  'A narrower form of FM specifying delays that excuse a party from delay penalties but do not excuse performance entirely. Common in EPC contracts.',
  '[AR] A narrower form of FM specifying delays that excuse a party from delay penalties but do not excuse performance entirely. Common in EPC contracts.',
  '"excusable delay", "extension of time", "EOT", "delay penalties excused", "force majeure event causing delay".',
  '[AR] "excusable delay", "extension of time", "EOT", "delay penalties excused", "force majeure event causing delay".',
  '{"delay_categories":{"type":"enum_list","required":false,"enum_values":["fm_event","employer_variation","employer_instruction","statutory_change","utility_failure","other"]},"notice_requirement":{"type":"text_excerpt","required":false},"eot_calculation_method":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'weather_downtime', 'force_majeure',
  'Weather Downtime', '[AR] Weather Downtime',
  'Specific provisions for weather-related delays, common in offshore drilling, charter party, and marine construction contracts.',
  '[AR] Specific provisions for weather-related delays, common in offshore drilling, charter party, and marine construction contracts.',
  '"weather downtime", "wave height", "wind speed", "weather standby rate", "meteorological downtime".',
  '[AR] "weather downtime", "wave height", "wind speed", "weather standby rate", "meteorological downtime".',
  '{"weather_threshold":{"type":"text_excerpt","required":false},"weather_standby_rate":{"type":"money","required":false},"weather_data_source":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'epidemic_pandemic', 'force_majeure',
  'Epidemic / Pandemic', '[AR] Epidemic / Pandemic',
  'Post-2020, many ADNOC contracts include explicit pandemic provisions distinct from generic FM. Where present, these take precedence over the general FM clause for pandemic-related events.',
  '[AR] Post-2020, many ADNOC contracts include explicit pandemic provisions distinct from generic FM. Where present, these take precedence over the general FM clause for pandemic-related events.',
  '"pandemic", "epidemic", "COVID", "public health emergency", "WHO declaration", "quarantine", "lockdown measures".',
  '[AR] "pandemic", "epidemic", "COVID", "public health emergency", "WHO declaration", "quarantine", "lockdown measures".',
  '{"declaration_authority":{"type":"enum","required":false,"enum_values":["who_declaration","uae_government","both"]},"relief_scope":{"type":"enum","required":false,"enum_values":["extension_of_time","suspension","price_relief","termination"]},"notice_period_days":{"type":"duration_days","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'government_action', 'force_majeure',
  'Government Action', '[AR] Government Action',
  'Performance excused or modified due to governmental, regulatory, or sanctions action — sometimes carved out separately from generic FM, particularly in international contracts.',
  '[AR] Performance excused or modified due to governmental, regulatory, or sanctions action — sometimes carved out separately from generic FM, particularly in international contracts.',
  '"government action", "regulatory change", "change in law", "expropriation", "nationalisation", "embargo by government".',
  '[AR] "government action", "regulatory change", "change in law", "expropriation", "nationalisation", "embargo by government".',
  '{"authority_scope":{"type":"enum","required":false,"enum_values":["uae","gcc","international","sanctioning_state_specific"]},"affected_obligations":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'sanctions_disruption', 'force_majeure',
  'Sanctions-Related Disruption', '[AR] Sanctions-Related Disruption',
  'Specific provisions addressing performance affected by sanctions designation of a counterparty or in a sanctioned jurisdiction. May be standalone or sub-clause of FM.',
  '[AR] Specific provisions addressing performance affected by sanctions designation of a counterparty or in a sanctioned jurisdiction. May be standalone or sub-clause of FM.',
  '"sanctions disruption", "sanctioned entity", "OFAC", "SDN", "designated counterparty", "sanctions-related termination".',
  '[AR] "sanctions disruption", "sanctioned entity", "OFAC", "SDN", "designated counterparty", "sanctions-related termination".',
  '{"sanctioning_authorities":{"type":"enum_list","required":false,"enum_values":["ofac","eu","un","uk","other"]},"automatic_suspension":{"type":"boolean","required":false},"termination_threshold_days":{"type":"duration_days","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'strike_lockout', 'force_majeure',
  'Strike / Lockout', '[AR] Strike / Lockout',
  'Labour disruptions; often carved out in detail because of the partial-FM treatment they receive in many jurisdictions.',
  '[AR] Labour disruptions; often carved out in detail because of the partial-FM treatment they receive in many jurisdictions.',
  '"strike", "lockout", "industrial action", "labour dispute", "trade union action".',
  '[AR] "strike", "lockout", "industrial action", "labour dispute", "trade union action".',
  '{"scope":{"type":"enum","required":false,"enum_values":["contractor_workforce","industry_wide","national","international"]},"excluded_categories":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

-- ---- FAMILY: termination (A.4) ---- 6 rows ----

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'termination_for_convenience', 'termination',
  'Termination for Convenience', '[AR] Termination for Convenience',
  'Right of one party (typically the principal/buyer) to terminate without cause, usually with notice and compensation provisions.',
  '[AR] Right of one party (typically the principal/buyer) to terminate without cause, usually with notice and compensation provisions.',
  '"termination for convenience", "termination without cause", "termination at will", "termination on notice".',
  '[AR] "termination for convenience", "termination without cause", "termination at will", "termination on notice".',
  '{"right_holder":{"type":"party_ref","required":false},"notice_period_days":{"type":"duration_days","required":false},"compensation_formula":{"type":"text_excerpt","required":false},"demobilisation_recovery":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'termination_for_cause', 'termination',
  'Termination for Cause', '[AR] Termination for Cause',
  'Termination triggered by defined breach categories. Usually the most-litigated termination provision.',
  '[AR] Termination triggered by defined breach categories. Usually the most-litigated termination provision.',
  '"termination for cause", "material breach", "persistent breach", "insolvency event", "termination notice", "cure period".',
  '[AR] "termination for cause", "material breach", "persistent breach", "insolvency event", "termination notice", "cure period".',
  '{"breach_categories":{"type":"enum_list","required":false,"enum_values":["material_breach","persistent_breach","insolvency","sanctions_designation","ipv_breach","hse_breach","anti_bribery_breach","other"]},"cure_period_days":{"type":"duration_days","required":false},"notice_method":{"type":"enum","required":false,"enum_values":["registered_post","courier","email","hand_delivery"]},"step_in_rights":{"type":"boolean","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'suspension', 'termination',
  'Suspension', '[AR] Suspension',
  'Right to suspend performance temporarily without terminating, often as a remedy short of termination.',
  '[AR] Right to suspend performance temporarily without terminating, often as a remedy short of termination.',
  '"suspend", "suspension of works", "suspension of services", "suspend performance", "right to suspend".',
  '[AR] "suspend", "suspension of works", "suspension of services", "suspend performance", "right to suspend".',
  '{"suspension_grounds":{"type":"enum_list","required":false,"enum_values":["employer_instruction","non_payment","safety_risk","regulatory_prohibition","fm_event"]},"max_suspension_days":{"type":"duration_days","required":false},"payment_during_suspension":{"type":"enum","required":false,"enum_values":["full","partial","none"]},"reactivation_notice_days":{"type":"duration_days","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'step_in_rights', 'termination',
  'Step-In Rights', '[AR] Step-In Rights',
  'Right of the principal (or a financier) to take over performance directly when the counterparty fails. Common in O&M and project finance.',
  '[AR] Right of the principal (or a financier) to take over performance directly when the counterparty fails. Common in O&M and project finance.',
  '"step-in", "step in rights", "employer to take over", "principal may assume", "lender step-in".',
  '[AR] "step-in", "step in rights", "employer to take over", "principal may assume", "lender step-in".',
  '{"trigger_conditions":{"type":"text_excerpt","required":false},"step_in_party":{"type":"party_ref","required":false},"notice_required_days":{"type":"duration_days","required":false},"retain_subcontractors":{"type":"boolean","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'termination_for_change_of_control', 'termination',
  'Termination for Change of Control', '[AR] Termination for Change of Control',
  'Termination right triggered by change in ownership or control of the counterparty, used to manage counterparty-substitution risk.',
  '[AR] Termination right triggered by change in ownership or control of the counterparty, used to manage counterparty-substitution risk.',
  '"change of control", "change in ownership", "acquisition", "merger", "ownership threshold", "UBO change".',
  '[AR] "change of control", "change in ownership", "acquisition", "merger", "ownership threshold", "UBO change".',
  '{"ownership_threshold_pct":{"type":"percentage","required":false},"ultimate_control_test":{"type":"boolean","required":false},"notice_period_days":{"type":"duration_days","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'prolonged_force_majeure_termination', 'termination',
  'Prolonged Force Majeure Termination', '[AR] Prolonged Force Majeure Termination',
  'Right to terminate when an FM event continues beyond a defined duration. Sub-clause of FM but extracted separately because the trigger is durational rather than event-typed.',
  '[AR] Right to terminate when an FM event continues beyond a defined duration. Sub-clause of FM but extracted separately because the trigger is durational rather than event-typed.',
  '"continued force majeure", "FM exceeds", "FM duration", "right to terminate after extended FM", "prolonged FM".',
  '[AR] "continued force majeure", "FM exceeds", "FM duration", "right to terminate after extended FM", "prolonged FM".',
  '{"fm_duration_threshold_days":{"type":"duration_days","required":false},"terminating_party":{"type":"enum","required":false,"enum_values":["principal_only","either_party","mutual_consent"]}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

-- ---- FAMILY: pricing (A.5) ---- 5 rows ----

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'price_review', 'pricing',
  'Price Review', '[AR] Price Review',
  'A clause permitting one or both parties to seek price adjustment when defined market or cost conditions change. The most strategically important clause family for energy contracts.',
  '[AR] A clause permitting one or both parties to seek price adjustment when defined market or cost conditions change. The most strategically important clause family for energy contracts.',
  '"price review", "price adjustment", "market price review", "contractual review mechanism", "trigger threshold", "Brent review".',
  '[AR] "price review", "price adjustment", "market price review", "contractual review mechanism", "trigger threshold", "Brent review".',
  '{"trigger_index":{"type":"index_marker","required":false},"trigger_threshold_high":{"type":"money","required":false},"trigger_threshold_low":{"type":"money","required":false},"review_window_days":{"type":"duration_days","required":false},"review_request_party":{"type":"enum","required":false,"enum_values":["buyer","seller","either"]},"review_period_days":{"type":"duration_days","required":false},"fallback_on_failure":{"type":"enum","required":false,"enum_values":["arbitration","continue_unchanged","termination","mediation"]},"adjustment_formula":{"type":"text_excerpt","required":false},"review_frequency_max_per_year":{"type":"integer","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'price_indexation', 'pricing',
  'Price Indexation', '[AR] Price Indexation',
  'Automatic price adjustment indexed to a defined market reference, applying continuously rather than on request.',
  '[AR] Automatic price adjustment indexed to a defined market reference, applying continuously rather than on request.',
  '"price indexation", "indexed to", "automatic adjustment", "linked to index", "formula price".',
  '[AR] "price indexation", "indexed to", "automatic adjustment", "linked to index", "formula price".',
  '{"base_index_value":{"type":"money","required":false},"reference_index":{"type":"index_marker","required":false},"adjustment_period_days":{"type":"duration_days","required":false},"adjustment_formula":{"type":"text_excerpt","required":false},"cap_floor":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'escalation', 'pricing',
  'Escalation', '[AR] Escalation',
  'Annual or periodic price increases tied to inflation, labour cost indices, or fixed percentages. Common in long-term O&M contracts.',
  '[AR] Annual or periodic price increases tied to inflation, labour cost indices, or fixed percentages. Common in long-term O&M contracts.',
  '"escalation", "price escalation", "annual increase", "CPI adjustment", "inflation-linked", "price variation".',
  '[AR] "escalation", "price escalation", "annual increase", "CPI adjustment", "inflation-linked", "price variation".',
  '{"escalation_basis":{"type":"enum","required":false,"enum_values":["cpi","wpi","fixed_pct","labour_index","composite"]},"escalation_pct_or_formula":{"type":"text_excerpt","required":false},"escalation_frequency":{"type":"enum","required":false,"enum_values":["annual","quarterly","other"]},"first_escalation_date":{"type":"date","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'most_favoured_pricing', 'pricing',
  'Most-Favoured Pricing', '[AR] Most-Favoured Pricing',
  'Most-favoured-customer or most-favoured-nation pricing — guarantee that the counterparty will not offer better terms to others.',
  '[AR] Most-favoured-customer or most-favoured-nation pricing — guarantee that the counterparty will not offer better terms to others.',
  '"most favoured", "MFN", "most favoured nation", "most favoured customer", "best price guarantee".',
  '[AR] "most favoured", "MFN", "most favoured nation", "most favoured customer", "best price guarantee".',
  '{"scope":{"type":"text_excerpt","required":false},"audit_right":{"type":"boolean","required":false},"reconciliation_period_days":{"type":"duration_days","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'take_or_pay', 'pricing',
  'Take or Pay', '[AR] Take or Pay',
  'Buyer must pay for a minimum quantity whether or not it actually takes delivery. Standard in long-term gas and crude supply.',
  '[AR] Buyer must pay for a minimum quantity whether or not it actually takes delivery. Standard in long-term gas and crude supply.',
  '"take or pay", "minimum quantity", "ship or pay", "deficiency payment", "make-up rights".',
  '[AR] "take or pay", "minimum quantity", "ship or pay", "deficiency payment", "make-up rights".',
  '{"minimum_quantity_per_period":{"type":"text_excerpt","required":false},"period":{"type":"enum","required":false,"enum_values":["monthly","quarterly","annual"]},"make_up_rights":{"type":"boolean","required":false},"make_up_window_days":{"type":"duration_days","required":false},"deficiency_payment_formula":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

-- ---- FAMILY: performance (A.6) ---- 6 rows ----

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'sla_performance', 'performance',
  'SLA / Performance Levels', '[AR] SLA / Performance Levels',
  'Defined service performance levels with measurement methodology, reporting, and consequences for breach.',
  '[AR] Defined service performance levels with measurement methodology, reporting, and consequences for breach.',
  '"service level", "SLA", "key performance indicator", "KPI", "uptime", "availability", "performance target".',
  '[AR] "service level", "SLA", "key performance indicator", "KPI", "uptime", "availability", "performance target".',
  '{"sla_metrics":{"type":"text_excerpt","required":false},"measurement_period":{"type":"enum","required":false,"enum_values":["monthly","quarterly"]},"reporting_obligation":{"type":"text_excerpt","required":false},"breach_threshold":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'liquidated_damages', 'performance',
  'Liquidated Damages', '[AR] Liquidated Damages',
  'Pre-agreed monetary penalties for delay, performance shortfall, or other defined breaches. Common in EPC.',
  '[AR] Pre-agreed monetary penalties for delay, performance shortfall, or other defined breaches. Common in EPC.',
  '"liquidated damages", "LD", "delay damages", "pre-agreed damages", "penalty for delay".',
  '[AR] "liquidated damages", "LD", "delay damages", "pre-agreed damages", "penalty for delay".',
  '{"ld_basis":{"type":"enum","required":false,"enum_values":["per_day_delay","per_unit_shortfall","per_event"]},"ld_rate":{"type":"money","required":false},"ld_cap":{"type":"money","required":false},"ld_carve_outs":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'cure_period', 'performance',
  'Cure Period', '[AR] Cure Period',
  'Period within which a defaulting party may remedy a breach before termination or other consequence applies.',
  '[AR] Period within which a defaulting party may remedy a breach before termination or other consequence applies.',
  '"cure period", "remedy notice", "notice to cure", "right to remedy", "remediation period".',
  '[AR] "cure period", "remedy notice", "notice to cure", "right to remedy", "remediation period".',
  '{"cure_period_days":{"type":"duration_days","required":false},"breaches_subject_to_cure":{"type":"text_excerpt","required":false},"notice_requirement":{"type":"boolean","required":false},"repeat_breach_treatment":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'performance_bond_guarantee', 'performance',
  'Performance Bond / Guarantee', '[AR] Performance Bond / Guarantee',
  'Bank guarantee, performance bond, or letter of credit securing performance.',
  '[AR] Bank guarantee, performance bond, or letter of credit securing performance.',
  '"performance bond", "bank guarantee", "performance guarantee", "letter of credit", "on-demand bond".',
  '[AR] "performance bond", "bank guarantee", "performance guarantee", "letter of credit", "on-demand bond".',
  '{"instrument_type":{"type":"enum","required":false,"enum_values":["bg","sblc","parent_guarantee","performance_bond"]},"instrument_value":{"type":"money","required":false},"validity_period_days":{"type":"duration_days","required":false},"draw_conditions":{"type":"text_excerpt","required":false},"issuing_bank_rating_requirement":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'key_personnel', 'performance',
  'Key Personnel', '[AR] Key Personnel',
  'Named personnel whose substitution requires principal approval. Common in services and consulting contracts.',
  '[AR] Key Personnel',
  '"key personnel", "named individuals", "key staff", "substitution approval", "replacement of key person".',
  '[AR] "key personnel", "named individuals", "key staff", "substitution approval", "replacement of key person".',
  '{"named_personnel_list":{"type":"text_excerpt","required":false},"substitution_approval_requirement":{"type":"text_excerpt","required":false},"substitution_notice_days":{"type":"duration_days","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'acceptance_testing', 'performance',
  'Acceptance Testing', '[AR] Acceptance Testing',
  'Procedures and criteria for acceptance of deliverables, milestones, or completed works.',
  '[AR] Procedures and criteria for acceptance of deliverables, milestones, or completed works.',
  '"acceptance test", "provisional acceptance", "completion certificate", "taking-over", "PAC", "FAC".',
  '[AR] "acceptance test", "provisional acceptance", "completion certificate", "taking-over", "PAC", "FAC".',
  '{"acceptance_criteria":{"type":"text_excerpt","required":false},"test_witness_requirement":{"type":"boolean","required":false},"retest_provisions":{"type":"text_excerpt","required":false},"provisional_acceptance_definition":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

-- ---- FAMILY: indemnity (A.7) ---- 5 rows ----

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'indemnity', 'indemnity',
  'Indemnity', '[AR] Indemnity',
  'Obligation to indemnify the other party against defined losses, claims, or liabilities. Carve-outs and exclusions are critical.',
  '[AR] Obligation to indemnify the other party against defined losses, claims, or liabilities. Carve-outs and exclusions are critical.',
  '"indemnify", "indemnification", "hold harmless", "indemnity obligation", "claims indemnity".',
  '[AR] "indemnify", "indemnification", "hold harmless", "indemnity obligation", "claims indemnity".',
  '{"indemnifying_party":{"type":"party_ref","required":false},"covered_losses":{"type":"enum_list","required":false,"enum_values":["third_party_claims","hse","ip_infringement","tax","data_breach","other"]},"excluded_losses":{"type":"text_excerpt","required":false},"indemnity_cap":{"type":"money","required":false},"notice_requirement":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'liability_cap', 'indemnity',
  'Liability Cap', '[AR] Liability Cap',
  'Aggregate cap on a party''s liability under the contract, with carve-outs for excluded liability categories.',
  '[AR] Aggregate cap on a party''s liability under the contract, with carve-outs for excluded liability categories.',
  '"liability cap", "aggregate liability", "maximum liability", "cap on liability", "overall cap".',
  '[AR] "liability cap", "aggregate liability", "maximum liability", "cap on liability", "overall cap".',
  '{"cap_value":{"type":"money","required":false},"cap_basis":{"type":"enum","required":false,"enum_values":["aggregate","per_event","annual"]},"excluded_categories":{"type":"enum_list","required":false,"enum_values":["gross_negligence","wilful_misconduct","hse","ip","confidentiality","sanctions_breach"]},"super_cap_for_excluded":{"type":"money","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'consequential_loss_exclusion', 'indemnity',
  'Consequential Loss Exclusion', '[AR] Consequential Loss Exclusion',
  'Exclusion of indirect, consequential, special, or punitive damages — heavily negotiated and varies by jurisdiction.',
  '[AR] Exclusion of indirect, consequential, special, or punitive damages — heavily negotiated and varies by jurisdiction.',
  '"consequential loss", "indirect loss", "loss of profit", "loss of revenue", "special damages", "exclusion of damages".',
  '[AR] "consequential loss", "indirect loss", "loss of profit", "loss of revenue", "special damages", "exclusion of damages".',
  '{"excluded_damage_types":{"type":"text_excerpt","required":false},"excluded_loss_types":{"type":"enum_list","required":false,"enum_values":["lost_profit","lost_revenue","loss_of_use","loss_of_production","reputational","other"]},"exception_to_exclusion":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'insurance', 'indemnity',
  'Insurance', '[AR] Insurance',
  'Required insurance coverages, limits, and terms.',
  '[AR] Required insurance coverages, limits, and terms.',
  '"insurance", "required coverage", "public liability", "professional indemnity", "marine insurance", "additional insured".',
  '[AR] "insurance", "required coverage", "public liability", "professional indemnity", "marine insurance", "additional insured".',
  '{"required_policies":{"type":"enum_list","required":false,"enum_values":["cgl","wc","pi","em","marine","env","po"]},"limit_per_policy":{"type":"money","required":false},"additional_insured_requirement":{"type":"boolean","required":false},"waiver_of_subrogation":{"type":"boolean","required":false},"certificate_obligation":{"type":"text_excerpt","required":false},"expiry_date_per_policy":{"type":"date","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'mutual_hold_harmless', 'indemnity',
  'Mutual Hold Harmless (Knock-for-Knock)', '[AR] Mutual Hold Harmless (Knock-for-Knock)',
  'Knock-for-knock indemnity — common in oil and gas service contracts. Each party indemnifies the other for damage to its own personnel and property regardless of fault.',
  '[AR] Knock-for-knock indemnity — common in oil and gas service contracts. Each party indemnifies the other for damage to its own personnel and property regardless of fault.',
  '"knock for knock", "mutual hold harmless", "each party bears its own", "KFK", "LOGIC form".',
  '[AR] "knock for knock", "mutual hold harmless", "each party bears its own", "KFK", "LOGIC form".',
  '{"scope":{"type":"enum","required":false,"enum_values":["personnel_only","personnel_and_property","broader"]},"carve_outs":{"type":"text_excerpt","required":false},"gross_negligence_exception":{"type":"boolean","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

-- ---- FAMILY: compliance (A.8) ---- 8 rows ----

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'sanctions_compliance', 'compliance',
  'Sanctions Compliance', '[AR] Sanctions Compliance',
  'Obligation not to deal with sanctioned entities or in sanctioned jurisdictions, with consequence provisions if a counterparty becomes sanctioned during the contract.',
  '[AR] Sanctions Compliance',
  '"sanctions compliance", "OFAC", "EU sanctions", "SDN list", "no dealings with sanctioned parties", "sanctions screening".',
  '[AR] "sanctions compliance", "OFAC", "EU sanctions", "SDN list", "no dealings with sanctioned parties", "sanctions screening".',
  '{"applicable_regimes":{"type":"enum_list","required":false,"enum_values":["ofac","eu","un","uk","uae","other"]},"screening_obligation":{"type":"text_excerpt","required":false},"counterparty_designation_consequence":{"type":"enum","required":false,"enum_values":["automatic_termination","suspension","renegotiation","review"]},"cooperation_obligation":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'anti_bribery_corruption', 'compliance',
  'Anti-Bribery and Corruption', '[AR] Anti-Bribery and Corruption',
  'Anti-bribery and anti-corruption obligations — typically references FCPA, UK Bribery Act, UAE Federal Law No. 31 of 2021.',
  '[AR] Anti-bribery and anti-corruption obligations — typically references FCPA, UK Bribery Act, UAE Federal Law No. 31 of 2021.',
  '"anti-bribery", "ABC", "FCPA", "UK Bribery Act", "no corrupt payments", "anti-corruption".',
  '[AR] "anti-bribery", "ABC", "FCPA", "UK Bribery Act", "no corrupt payments", "anti-corruption".',
  '{"applicable_laws":{"type":"enum_list","required":false,"enum_values":["fcpa","ukba","uae_federal","other"]},"audit_right":{"type":"boolean","required":false},"termination_for_breach":{"type":"boolean","required":false},"training_obligation":{"type":"boolean","required":false},"agent_certification":{"type":"boolean","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'hse_compliance', 'compliance',
  'HSE Compliance', '[AR] HSE Compliance',
  'Health, Safety, and Environment obligations. ADNOC HSE standards (ADNOC HSE Manual) are extensively referenced in their contracts.',
  '[AR] Health, Safety, and Environment obligations. ADNOC HSE standards are extensively referenced in their contracts.',
  '"HSE", "health safety environment", "ADNOC HSE", "safety management", "incident reporting", "safe working".',
  '[AR] "HSE", "health safety environment", "ADNOC HSE", "safety management", "incident reporting", "safe working".',
  '{"standards_referenced":{"type":"text_excerpt","required":false},"reporting_obligation":{"type":"text_excerpt","required":false},"incident_notification_period_hours":{"type":"integer","required":false},"audit_rights":{"type":"boolean","required":false},"corrective_action_period_days":{"type":"duration_days","required":false},"hse_kpis":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'icv_in_country_value', 'compliance',
  'ICV (In-Country Value)', 'القيمة المضافة الوطنية (ICV)',
  'In-Country Value commitment — a UAE-specific requirement to maximise local content (UAE-national workforce, locally-procured goods and services). Mandatory in many ADNOC contracts.',
  'التزام القيمة المضافة الوطنية — متطلب إماراتي لتعظيم المحتوى المحلي في القوى العاملة والسلع والخدمات. إلزامي في العديد من عقود أدنوك.',
  '"ICV", "in-country value", "local content", "Emiratisation", "Tawteen", "ADNOC ICV programme".',
  '"القيمة المضافة الوطنية", "ICV", "المحتوى المحلي", "التوطين", "برنامج ICV أدنوك".',
  '{"icv_target_pct":{"type":"percentage","required":false},"icv_certification_requirement":{"type":"boolean","required":false},"icv_audit_rights":{"type":"boolean","required":false},"icv_shortfall_remedy":{"type":"enum","required":false,"enum_values":["penalty","rectification_plan","termination"]},"icv_reporting_period_months":{"type":"integer","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'data_protection', 'compliance',
  'Data Protection', '[AR] Data Protection',
  'Data protection and privacy obligations. UAE PDPL and GDPR references where applicable.',
  '[AR] Data protection and privacy obligations. UAE PDPL and GDPR references where applicable.',
  '"data protection", "PDPL", "GDPR", "personal data", "data subject", "privacy", "data processing".',
  '[AR] "data protection", "PDPL", "GDPR", "personal data", "data subject", "privacy", "data processing".',
  '{"applicable_laws":{"type":"enum_list","required":false,"enum_values":["uae_pdpl","gdpr","other"]},"data_categories":{"type":"text_excerpt","required":false},"cross_border_transfer_restrictions":{"type":"boolean","required":false},"breach_notification_period_hours":{"type":"integer","required":false},"data_subject_rights_handling":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'environmental', 'compliance',
  'Environmental', '[AR] Environmental',
  'Environmental obligations beyond generic HSE — including emissions, waste, water, biodiversity provisions.',
  '[AR] Environmental obligations beyond generic HSE — including emissions, waste, water, biodiversity provisions.',
  '"environmental", "emissions", "waste management", "carbon", "biodiversity", "environmental impact".',
  '[AR] "environmental", "emissions", "waste management", "carbon", "biodiversity", "environmental impact".',
  '{"environmental_standards":{"type":"text_excerpt","required":false},"reporting_obligation":{"type":"text_excerpt","required":false},"remediation_obligation":{"type":"text_excerpt","required":false},"environmental_indemnity":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'export_control', 'compliance',
  'Export Control', '[AR] Export Control',
  'Restrictions on export of controlled technology, materials, or data.',
  '[AR] Restrictions on export of controlled technology, materials, or data.',
  '"export control", "EAR", "ITAR", "dual-use", "controlled technology", "export licence".',
  '[AR] "export control", "EAR", "ITAR", "dual-use", "controlled technology", "export licence".',
  '{"applicable_regimes":{"type":"enum_list","required":false,"enum_values":["us_ear","us_itar","eu_dual_use","uae","other"]},"classification_obligation":{"type":"boolean","required":false},"license_requirement":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'regulatory_change', 'compliance',
  'Regulatory Change', '[AR] Regulatory Change',
  'Provisions allocating risk and cost of regulatory changes during the contract term.',
  '[AR] Provisions allocating risk and cost of regulatory changes during the contract term.',
  '"change in law", "regulatory change", "new regulation", "legislative change", "compliance cost allocation".',
  '[AR] "change in law", "regulatory change", "new regulation", "legislative change", "compliance cost allocation".',
  '{"change_in_law_definition":{"type":"text_excerpt","required":false},"risk_allocation":{"type":"enum","required":false,"enum_values":["principal","contractor","shared","renegotiation"]},"notice_period_days":{"type":"duration_days","required":false},"cost_pass_through":{"type":"boolean","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

-- ---- FAMILY: governance (A.9) ---- 5 rows ----

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'governing_law', 'governance',
  'Governing Law', '[AR] Governing Law',
  'The substantive law governing the contract.',
  '[AR] The substantive law governing the contract.',
  '"governing law", "this agreement shall be governed by", "applicable law", "law of".',
  '[AR] "governing law", "this agreement shall be governed by", "applicable law", "law of".',
  '{"jurisdiction":{"type":"jurisdiction","required":false,"enum_values":["english","adgm","difc","uae_federal","abu_dhabi","sharjah","dubai","other"]},"excluded_provisions":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'dispute_resolution', 'governance',
  'Dispute Resolution', '[AR] Dispute Resolution',
  'Forum, procedure, and rules for dispute resolution. Multi-tier clauses (negotiation → mediation → arbitration) are common.',
  '[AR] Forum, procedure, and rules for dispute resolution. Multi-tier clauses are common.',
  '"dispute resolution", "arbitration", "mediation", "DIAC", "ICC", "LCIA", "escalation clause", "expert determination".',
  '[AR] "dispute resolution", "arbitration", "mediation", "DIAC", "ICC", "LCIA", "escalation clause".',
  '{"primary_forum":{"type":"enum","required":false,"enum_values":["adgm_court","difc_court","uae_federal_court","english_court","arbitration","other"]},"arbitration_seat":{"type":"text_excerpt","required":false},"arbitration_rules":{"type":"enum","required":false,"enum_values":["icc","lcia","uncitral","dial","iaccu","other"]},"arbitrator_count":{"type":"integer","required":false},"tier_1_negotiation_period_days":{"type":"duration_days","required":false},"tier_2_mediation_period_days":{"type":"duration_days","required":false},"language":{"type":"text","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'notices', 'governance',
  'Notices', '[AR] Notices',
  'How formal notices under the contract must be delivered.',
  '[AR] How formal notices under the contract must be delivered.',
  '"notices", "notice to be given", "formal notice", "delivery of notices", "deemed receipt".',
  '[AR] "notices", "notice to be given", "formal notice", "delivery of notices", "deemed receipt".',
  '{"notice_address_per_party":{"type":"address","required":false},"permitted_methods":{"type":"enum_list","required":false,"enum_values":["registered_post","courier","email","hand","fax"]},"deemed_receipt_period_days":{"type":"duration_days","required":false},"notice_effectiveness_rules":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'entire_agreement', 'governance',
  'Entire Agreement', '[AR] Entire Agreement',
  'Statement that the contract represents the entire agreement and supersedes prior communications. Affects how representations and warranties are interpreted.',
  '[AR] Statement that the contract represents the entire agreement and supersedes prior communications.',
  '"entire agreement", "supersedes all previous", "complete agreement", "integration clause".',
  '[AR] "entire agreement", "supersedes all previous", "complete agreement", "integration clause".',
  '{"scope":{"type":"text_excerpt","required":false},"carve_outs":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'severability', 'governance',
  'Severability', '[AR] Severability',
  'Treatment of unenforceable provisions.',
  '[AR] Treatment of unenforceable provisions.',
  '"severability", "severable", "invalid provision", "unenforceable clause", "blue-pencil".',
  '[AR] "severability", "severable", "invalid provision", "unenforceable clause".',
  '{"treatment":{"type":"enum","required":false,"enum_values":["strike_unenforceable_only","reform_to_intent","renegotiate"]}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

-- ---- FAMILY: operational (A.10) ---- 7 rows ----

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'term_and_renewal', 'operational',
  'Term and Renewal', '[AR] Term and Renewal',
  'Contract duration and renewal mechanics.',
  '[AR] Contract duration and renewal mechanics.',
  '"term of agreement", "effective date", "expiry date", "renewal", "auto-renewal", "renewal notice".',
  '[AR] "term of agreement", "effective date", "expiry date", "renewal", "auto-renewal", "renewal notice".',
  '{"effective_date":{"type":"date","required":false},"expiry_date":{"type":"date","required":false},"initial_term_months":{"type":"integer","required":false},"renewal_type":{"type":"enum","required":false,"enum_values":["auto_renewal","renewal_by_notice","renegotiation","non_renewable"]},"renewal_term_months":{"type":"integer","required":false},"renewal_notice_period_days":{"type":"duration_days","required":false},"renewal_notice_party":{"type":"party_ref","required":false},"max_renewals":{"type":"integer","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'assignment_novation', 'operational',
  'Assignment / Novation', '[AR] Assignment / Novation',
  'Restrictions on transferring rights and obligations to third parties.',
  '[AR] Restrictions on transferring rights and obligations to third parties.',
  '"assignment", "novation", "transfer of rights", "consent to assign", "permitted assignee".',
  '[AR] "assignment", "novation", "transfer of rights", "consent to assign", "permitted assignee".',
  '{"consent_required":{"type":"boolean","required":false},"consent_unreasonable_withholding":{"type":"boolean","required":false},"permitted_assignees":{"type":"enum_list","required":false,"enum_values":["affiliates","financiers","none","other"]},"notice_period_days":{"type":"duration_days","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'change_order_variation', 'operational',
  'Change Order / Variation', '[AR] Change Order / Variation',
  'Procedures for changes to scope, schedule, or price during contract execution.',
  '[AR] Procedures for changes to scope, schedule, or price during contract execution.',
  '"change order", "variation", "variation order", "scope change", "VO", "CO".',
  '[AR] "change order", "variation", "variation order", "scope change", "VO", "CO".',
  '{"variation_initiator":{"type":"enum","required":false,"enum_values":["principal_only","either_party"]},"variation_pricing_method":{"type":"enum","required":false,"enum_values":["schedule_of_rates","open_book","negotiated","fixed_premium"]},"dispute_resolution_for_variation":{"type":"text_excerpt","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'audit_rights', 'operational',
  'Audit Rights', '[AR] Audit Rights',
  'Right to audit counterparty records — financial, operational, ICV, HSE, anti-bribery.',
  '[AR] Right to audit counterparty records — financial, operational, ICV, HSE, anti-bribery.',
  '"audit rights", "right to audit", "access to records", "inspection rights", "financial audit".',
  '[AR] "audit rights", "right to audit", "access to records", "inspection rights", "financial audit".',
  '{"audit_scope":{"type":"enum_list","required":false,"enum_values":["financial","operational","icv","hse","abc","data"]},"notice_period_days":{"type":"duration_days","required":false},"audit_frequency_per_year":{"type":"integer","required":false},"record_retention_years":{"type":"integer","required":false},"audit_cost_allocation":{"type":"enum","required":false,"enum_values":["principal","shared","discrepancy_based"]}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'confidentiality', 'operational',
  'Confidentiality', '[AR] Confidentiality',
  'Confidentiality obligations and exceptions.',
  '[AR] Confidentiality obligations and exceptions.',
  '"confidentiality", "confidential information", "NDA", "non-disclosure", "proprietary information".',
  '[AR] "confidentiality", "confidential information", "NDA", "non-disclosure", "proprietary information".',
  '{"survival_period_years":{"type":"integer","required":false},"permitted_disclosures":{"type":"enum_list","required":false,"enum_values":["legal_compulsion","regulatory","advisors","affiliates"]},"return_or_destroy_obligation":{"type":"boolean","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'ip_rights', 'operational',
  'IP Rights', '[AR] IP Rights',
  'Intellectual property ownership, licensing, and use rights.',
  '[AR] Intellectual property ownership, licensing, and use rights.',
  '"intellectual property", "IP", "ownership of IP", "license", "foreground IP", "background IP".',
  '[AR] "intellectual property", "IP", "ownership of IP", "license", "foreground IP", "background IP".',
  '{"ip_ownership_default":{"type":"enum","required":false,"enum_values":["principal","contractor","joint","foreground_background_split"]},"license_grants":{"type":"text_excerpt","required":false},"survival_post_termination":{"type":"boolean","required":false}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

INSERT INTO clause_taxonomy (tenant_id, clause_type_id, family, display_name_en, display_name_ar, definition_en, definition_ar, identification_cues_en, identification_cues_ar, parameter_schema, version, is_deprecated, data_classification, created_by, updated_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'subcontracting', 'operational',
  'Subcontracting', '[AR] Subcontracting',
  'Rights to subcontract performance, with consent and flow-down provisions.',
  '[AR] Rights to subcontract performance, with consent and flow-down provisions.',
  '"subcontracting", "subcontract", "sub-contractor", "outsourcing", "pre-approved subcontractors".',
  '[AR] "subcontracting", "subcontract", "sub-contractor", "outsourcing", "pre-approved subcontractors".',
  '{"consent_required":{"type":"boolean","required":false},"pre_approved_subcontractors":{"type":"text_excerpt","required":false},"flow_down_obligations":{"type":"enum_list","required":false,"enum_values":["hse","abc","sanctions","icv","data_protection","all"]},"subcontractor_liability":{"type":"enum","required":false,"enum_values":["contractor_remains_liable","several","joint_and_several"]}}'::jsonb,
  1, FALSE, 'demo', NULL, NULL, TRUE
) ON CONFLICT (tenant_id, clause_type_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (143, '143_crd_seed_clause_taxonomy_annex_a', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 143;
-- DELETE FROM clause_taxonomy WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
--   AND data_classification = 'demo';
-- ============================================================
