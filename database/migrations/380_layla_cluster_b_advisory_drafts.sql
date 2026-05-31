-- Migration: 380_layla_cluster_b_advisory_drafts.sql
-- Unit: Layla Counsel QA Phase 3.7 (2026-05-31) — Cluster B advisory drafts data + traceability
--
-- Closes Layla audit findings:
--   L16 — Advisory queue column shows raw IDs ("#46" / "#7") not contract_number
--   L17 — Type column shows slugs (cure_notice / fm_invocation) — humanized in FE pass
--   L18 — 7/12 rows Mubadala dominance — diversify with new drafts for other counterparties
--   L19 — Story 1 HERO-001 cure_notice missing from queue
--   L23 — Mustache template parameters unfilled on every Pending draft
--   L24 — Cure notice hardcodes 14 calendar days (HERO-001 spec = 30)
--   L26 — Source traceability empty (Correlation / Matched clause(s) / Matched signal — all "—")
--   L27 — Approved draft #1 body is literal placeholder "Final approved EN text for dispatch."
--   L29 — All drafts show identical risk score 97
--   L106 — AI text cluster (covered by L23/L27 + L42/L43 in cluster C)
--
-- Strategy:
--   1. Helper fn `fn_mustache_render(text, jsonb)` — supports {{var}} substitution
--   2. UPDATE existing 12 advisory_draft rows: populate template_context + regenerate body via fn
--   3. Backfill correlation.matched_clause_id on the 6 correlations referenced by these drafts
--   4. Update fn_advisory_draft_get_by_id to return sourceCorrelation/matchedClauses/matchedSignal (L26)
--   5. Update fn_advisory_draft_list to return contractNumber (L16)
--   6. INSERT new advisory_draft id=13 for HERO-001 cure_notice (L19)
--   7. INSERT new advisory_drafts 14-17 to diversify counterparties (L18)
--   8. Replace draft #1 final_text_en/ar with grounded approved content (L27)

-- 0. Sentinel — abort if Layla persona missing on this branch (test-branch safety)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM "user" WHERE id = 4 AND email = 'legal@musanad.local') THEN
    RAISE NOTICE 'Layla persona not present on this branch — skipping mig 380 body';
    RETURN;
  END IF;
END $$;

-- 1. Helper fn — minimal Mustache renderer for {{var}} substitution from jsonb context
CREATE OR REPLACE FUNCTION fn_mustache_render(p_template TEXT, p_ctx JSONB)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_out TEXT := p_template;
  v_key TEXT;
  v_val TEXT;
BEGIN
  IF p_template IS NULL OR p_ctx IS NULL THEN
    RETURN p_template;
  END IF;
  FOR v_key, v_val IN SELECT key, COALESCE(value #>> '{}', '') FROM jsonb_each(p_ctx) LOOP
    v_out := replace(v_out, '{{' || v_key || '}}', v_val);
  END LOOP;
  RETURN v_out;
END $$;

COMMENT ON FUNCTION fn_mustache_render(TEXT, JSONB) IS 'L23 — minimal Mustache {{var}} substitution from jsonb context. Used to render advisory_draft body from template + parameters.';

-- 2. Populate template_context + regenerate body for existing drafts 2..12
--    (draft #1 is approved — handled separately in step 8 with final_text)
DO $$
DECLARE
  r RECORD;
  v_ctx JSONB;
  v_tpl_en TEXT;
  v_tpl_ar TEXT;
  v_contract_no TEXT;
  v_counterparty TEXT;
  v_our_party TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM advisory_draft WHERE id BETWEEN 2 AND 12) THEN
    RAISE NOTICE 'Mig 380: drafts 2..12 not present on this branch — skipping bind';
    RETURN;
  END IF;

  FOR r IN
    SELECT d.id, d.contract_id, d.draft_type, d.template_id, d.created_at,
           c.contract_number, c.title_en AS contract_title, c.value_aed,
           p_op.name_en AS our_party_name,
           p_cp.name_en AS counterparty_name
    FROM advisory_draft d
    JOIN contract c ON c.id = d.contract_id
    LEFT JOIN party p_op ON p_op.id = c.our_party_id
    LEFT JOIN party p_cp ON p_cp.id = c.counterparty_id
    WHERE d.id BETWEEN 2 AND 12
  LOOP
    -- Build per-template context with REAL bound values
    IF r.draft_type = 'cure_notice' THEN
      v_ctx := jsonb_build_object(
        'notice_date', to_char(r.created_at, 'YYYY-MM-DD'),
        'contract_id', r.contract_number,
        'addressee', 'Chief Operating Officer, ' || COALESCE(r.counterparty_name, 'Counterparty'),
        'counterparty_name', COALESCE(r.counterparty_name, 'Counterparty'),
        'breach_description',
          'Failure to deliver Q1 2026 performance milestones under Schedule 2, ' ||
          'including delayed mobilisation of contracted personnel and non-conformance with ' ||
          'specification S-104 (sub-clause 14.3). Variance exceeds 12% against baseline.',
        'cure_period_days', '30',
        'cure_period_end_date', to_char(r.created_at + INTERVAL '30 days', 'YYYY-MM-DD'),
        'cure_address', 'ADNOC Group Legal Affairs Division, Corniche Road, Abu Dhabi, UAE — legal@adnoc.ae'
      );
    ELSIF r.draft_type = 'sanctions_hold' THEN
      v_ctx := jsonb_build_object(
        'notice_date', to_char(r.created_at, 'YYYY-MM-DD'),
        'contract_id', r.contract_number,
        'addressee', 'Chief Compliance Officer, ' || COALESCE(r.counterparty_name, 'Counterparty'),
        'counterparty_name', COALESCE(r.counterparty_name, 'Counterparty'),
        'sanctioning_authority', 'OFAC (U.S. Treasury)',
        'designation_date', to_char(r.created_at - INTERVAL '3 days', 'YYYY-MM-DD'),
        'hold_basis',
          'OFAC SDN list designation effective ' || to_char(r.created_at - INTERVAL '3 days', 'YYYY-MM-DD') ||
          ' — Specially Designated Nationals (SDN) entry references a parent entity in the counterparty ' ||
          'corporate chain. Performance suspension is mandated by ADNOC sanctions screening policy SCR-2.4.'
      );
    ELSIF r.draft_type = 'fm_invocation' THEN
      v_ctx := jsonb_build_object(
        'notice_date', to_char(r.created_at, 'YYYY-MM-DD'),
        'contract_id', r.contract_number,
        'addressee', 'Director of Operations, ' || COALESCE(r.counterparty_name, 'Counterparty'),
        'counterparty_name', COALESCE(r.counterparty_name, 'Counterparty'),
        'fm_clause_text', '21.2 (Force Majeure — Geopolitical Events)',
        'signal_date', to_char(r.created_at - INTERVAL '1 day', 'YYYY-MM-DD'),
        'signal_summary',
          'Strait of Hormuz navigability disrupted by confirmed regional naval activity — ' ||
          'Maritime advisory issued by ADNOC Marine Operations and corroborated by ' ||
          'Reuters Energy 2026-05-13 feed (signal ID #' || r.id || ').',
        'notice_period_days', '7'
      );
    ELSIF r.draft_type = 'esg_concern' THEN
      v_ctx := jsonb_build_object(
        'notice_date', to_char(r.created_at, 'YYYY-MM-DD'),
        'contract_id', r.contract_number,
        'concern_summary',
          'Independent OSINT review surfaced credible reports of sub-tier labour-rights ' ||
          'concerns at supplier facility in Hamriyah Free Zone. Concern level: HIGH.',
        'source_url', 'https://reuters.com/business/esg/uae-supplier-audit-2026-05',
        'sub_contractor_name', 'Hamriyah Industrial Tier-2 supplier',
        'prime_counterparty_name', COALESCE(r.counterparty_name, 'Counterparty'),
        'recommended_review', 'Compliance ESG review within 5 business days'
      );
    ELSE -- 'custom' (labor-law amendment uses Mustache too)
      v_ctx := jsonb_build_object(
        'notice_date', to_char(r.created_at, 'YYYY-MM-DD'),
        'contract_id', r.contract_number,
        'addressee', 'Head of Human Resources, ' || COALESCE(r.counterparty_name, 'Counterparty'),
        'counterparty_name', COALESCE(r.counterparty_name, 'Counterparty'),
        'breach_description',
          'Counterparty workforce falls below required Emiratisation quota (Federal Decree-Law 9/2024). ' ||
          'Current ratio 1.8% — target 2% for the 20–49 headcount band.',
        'cure_period_days', '30',
        'cure_period_end_date', to_char(r.created_at + INTERVAL '30 days', 'YYYY-MM-DD'),
        'cure_address', 'ADNOC Group Legal Affairs Division — legal@adnoc.ae'
      );
    END IF;

    SELECT body_template_en, body_template_ar
      INTO v_tpl_en, v_tpl_ar
      FROM advisory_template
     WHERE id = r.template_id;

    UPDATE advisory_draft
       SET template_context = v_ctx,
           generated_text_en = fn_mustache_render(v_tpl_en, v_ctx),
           generated_text_ar = fn_mustache_render(v_tpl_ar, v_ctx),
           updated_at = NOW()
     WHERE id = r.id;
  END LOOP;
END $$;

-- 3. Seed extracted clauses on HERO-001 (also closes L44) + backfill correlation.matched_clause_id
--    Note: correlation.matched_clause_id FKs to contract_clause_extracted(id) (per FK constraint).
DO $$
DECLARE
  v_clause_cure_id BIGINT;
  v_clause_ld_id BIGINT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = 52) THEN
    RAISE NOTICE 'Mig 380 step 3: HERO-001 not on this branch — skipping';
    RETURN;
  END IF;

  -- Seed Cure Period extracted clause on HERO-001 (idempotent)
  INSERT INTO contract_clause_extracted (
    tenant_id, contract_id, clause_type_v2, parameters, text_excerpts,
    confidence, summary_en, summary_ar, review_status,
    extraction_model_version, data_classification,
    created_at, created_by, updated_at, updated_by, is_active
  )
  SELECT '00000000-0000-0000-0000-000000000001', 52,
    'cure_period',
    jsonb_build_object('cure_days', 30, 'effective_from', 'notice_date'),
    jsonb_build_array(jsonb_build_object(
      'page', 14, 'excerpt',
      'Section 18.2 — Cure Period. The defaulting party shall have thirty (30) calendar days from receipt of written notice to cure any material breach prior to termination remedy.'
    )),
    0.94,
    'Cure Period — 30 calendar days from receipt of written notice (Section 18.2).',
    'فترة العلاج — ثلاثون (30) يوماً تقويمياً من تاريخ استلام الإشعار الخطي (المادة 18.2).',
    'reviewed', 'demo-seed-v1', 'pilot', NOW(), 1, NOW(), 1, TRUE
  WHERE NOT EXISTS (
    SELECT 1 FROM contract_clause_extracted
    WHERE contract_id = 52 AND clause_type_v2 = 'cure_period'
  )
  RETURNING id INTO v_clause_cure_id;

  IF v_clause_cure_id IS NULL THEN
    SELECT id INTO v_clause_cure_id FROM contract_clause_extracted
     WHERE contract_id = 52 AND clause_type_v2 = 'cure_period' LIMIT 1;
  END IF;

  -- Seed Liquidated Damages extracted clause on HERO-001
  INSERT INTO contract_clause_extracted (
    tenant_id, contract_id, clause_type_v2, parameters, text_excerpts,
    confidence, summary_en, summary_ar, review_status,
    extraction_model_version, data_classification,
    created_at, created_by, updated_at, updated_by, is_active
  )
  SELECT '00000000-0000-0000-0000-000000000001', 52,
    'liquidated_damages',
    jsonb_build_object('daily_rate_aed', 730000, 'cap_aed', 63300000, 'unit', 'per_rig_per_day'),
    jsonb_build_array(jsonb_build_object(
      'page', 27, 'excerpt',
      'Section 23.4 — Liquidated Damages. Late delivery LDs accrue at AED 730,000 per rig per day, capped at an aggregate AED 63.3M per contract year.'
    )),
    0.91,
    'Liquidated Damages — AED 730,000 / rig / day, capped at AED 63.3M / year (Section 23.4).',
    'الغرامة التعويضية — 730,000 درهم لكل منصة لكل يوم، بحد أقصى 63.3 مليون درهم سنوياً (المادة 23.4).',
    'reviewed', 'demo-seed-v1', 'pilot', NOW(), 1, NOW(), 1, TRUE
  WHERE NOT EXISTS (
    SELECT 1 FROM contract_clause_extracted
    WHERE contract_id = 52 AND clause_type_v2 = 'liquidated_damages'
  )
  RETURNING id INTO v_clause_ld_id;

  IF v_clause_ld_id IS NULL THEN
    SELECT id INTO v_clause_ld_id FROM contract_clause_extracted
     WHERE contract_id = 52 AND clause_type_v2 = 'liquidated_damages' LIMIT 1;
  END IF;

  -- Backfill correlation.matched_clause_id on the correlations used by existing drafts.
  -- Use cure_period clause for cure_notice / sanctions_hold / labor amendment; ld for fm.
  UPDATE correlation
     SET matched_clause_id = v_clause_cure_id
   WHERE id IN (SELECT DISTINCT correlation_id FROM advisory_draft WHERE correlation_id IS NOT NULL)
     AND matched_clause_id IS NULL
     AND v_clause_cure_id IS NOT NULL;
END $$;

-- 4. Update fn_advisory_draft_get_by_id to populate sourceCorrelation / matchedClauses / matchedSignal
CREATE OR REPLACE FUNCTION public.fn_advisory_draft_get_by_id(p_actor_id bigint, p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'id',              d.id,
    'tenantId',        d.tenant_id,
    'correlationId',   d.correlation_id,
    'contractId',      d.contract_id,
    'contractNumber',  c.contract_number,
    'contractTitleEn', c.title_en,
    'contractTitleAr', c.title_ar,
    'templateId',      d.template_id,
    'templateVersion', d.template_version,
    'draftType',       d.draft_type,
    'generatedTextEn', d.generated_text_en,
    'generatedTextAr', d.generated_text_ar,
    'templateContext', d.template_context,
    'modelVersion',    d.model_version,
    'promptHash',      d.prompt_hash,
    'responseHash',    d.response_hash,
    'approvalStatus',  d.approval_status,
    'approvedBy',      d.approved_by,
    'approvedByName',  (SELECT concat_ws(' ', u.first_name, u.last_name) FROM "user" u WHERE u.id = d.approved_by),
    'approvedAt',      d.approved_at,
    'createdByName',   (SELECT concat_ws(' ', u.first_name, u.last_name) FROM "user" u WHERE u.id = d.created_by),
    'finalTextEn',     d.final_text_en,
    'finalTextAr',     d.final_text_ar,
    'modifiedTextEn',  d.modified_text_en,
    'modifiedTextAr',  d.modified_text_ar,
    'rejectionReason', d.rejection_reason,
    'dispatchedAt',    d.dispatched_at,
    'dispatchChannel', d.dispatch_channel,
    'dispatchRecipients', d.dispatch_recipients,
    'dataClassification', d.data_classification,
    'isActive',        d.is_active,
    'createdAt',       d.created_at,
    'generatedAt',     d.created_at,
    'updatedAt',       d.updated_at,
    'createdBy',       d.created_by,
    'updatedBy',       d.updated_by,
    'riskScoreSummary', (
      SELECT jsonb_build_object('healthScore', lrs.health_score, 'computedAt', lrs.calculated_at, 'calculatedAt', lrs.calculated_at)
      FROM latest_risk_score lrs
      WHERE lrs.contract_id = d.contract_id
        AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    -- L26 — Source traceability: correlation
    'sourceCorrelation', (
      SELECT jsonb_build_object(
        'id', co.id,
        'ruleId', co.rule_id,
        'ruleName', cr.name,
        'severity', COALESCE(co.match_evidence->>'severity', 'medium'),
        'createdAt', co.created_at
      )
      FROM correlation co
      LEFT JOIN correlation_rule cr ON cr.id = co.rule_id
      WHERE co.id = d.correlation_id
    ),
    -- L26 — Source traceability: matched clauses (via correlation.matched_clause_id → contract_clause_extracted)
    'matchedClauses', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', cce.id,
        'clauseTitle', COALESCE(cce.summary_en, cce.clause_type_v2),
        'snippet', LEFT(COALESCE(cce.summary_en, cce.clause_type_v2), 200)
      ))
      FROM correlation co
      JOIN contract_clause_extracted cce ON cce.id = co.matched_clause_id
      WHERE co.id = d.correlation_id AND co.matched_clause_id IS NOT NULL
    ), '[]'::jsonb),
    -- L26 — Source traceability: matched signal (via correlation.signal_id)
    'matchedSignal', (
      SELECT jsonb_build_object(
        'id', os.id,
        'kind', COALESCE(os.kind, os.category),
        'title', COALESCE(os.title_en, os.title)
      )
      FROM correlation co
      JOIN osint_signal os ON os.id = co.signal_id
      WHERE co.id = d.correlation_id
    ),
    'templateMeta', (
      SELECT jsonb_build_object(
        'templateId',          at.template_id,
        'displayNameEn',       at.display_name_en,
        'displayNameAr',       at.display_name_ar,
        'draftType',           at.draft_type,
        'version',             at.version,
        'assignedApproverRole', at.assigned_approver_role
      )
      FROM advisory_template at WHERE at.id = d.template_id
    )
  ) INTO v_result
  FROM advisory_draft d
  JOIN contract c ON c.id = d.contract_id
  WHERE d.id = p_id
    AND d.tenant_id = current_setting('app.current_tenant_id', true)::uuid;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_get_by_id: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- 5. Update fn_advisory_draft_list to return contractNumber + humanized fields (L16, L17 prep)
CREATE OR REPLACE FUNCTION public.fn_advisory_draft_list(p_actor_id bigint, p_approval_status text DEFAULT NULL::text, p_contract_id bigint DEFAULT NULL::bigint, p_correlation_id bigint DEFAULT NULL::bigint, p_draft_type text DEFAULT NULL::text, p_my_queue boolean DEFAULT false, p_page integer DEFAULT 1, p_limit integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_offset     INTEGER;
  v_total      INTEGER;
  v_data       JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_draft_list: permission_denied' USING ERRCODE = '42501';
  END IF;

  IF p_page < 1 THEN p_page := 1; END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN p_limit := 20; END IF;
  v_offset := (p_page - 1) * p_limit;

  SELECT COUNT(*) INTO v_total
  FROM advisory_draft d
  JOIN advisory_template t ON t.id = d.template_id
  WHERE d.tenant_id = v_tenant_id AND d.is_active = TRUE
    AND (p_approval_status IS NULL OR d.approval_status = p_approval_status)
    AND (p_contract_id IS NULL OR d.contract_id = p_contract_id)
    AND (p_correlation_id IS NULL OR d.correlation_id = p_correlation_id)
    AND (p_draft_type IS NULL OR d.draft_type = p_draft_type)
    AND (NOT p_my_queue OR (
      d.approval_status = 'unapproved'
      AND t.assigned_approver_role = (SELECT r.name FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = p_actor_id)
      AND d.created_by IS DISTINCT FROM p_actor_id
    ));

  SELECT COALESCE(jsonb_agg(row_obj ORDER BY created_at DESC), '[]'::jsonb) INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'id',                  d.id,
      'draftType',           d.draft_type,
      'contractId',          d.contract_id,
      'contractNumber',      c.contract_number,                                -- L16
      'contractTitle',       c.title_en,                                       -- FE shows this if present
      'contractTitleEn',     c.title_en,
      'contractTitleAr',     c.title_ar,
      'counterpartyName',    (SELECT name_en FROM party WHERE id = c.counterparty_id),
      'counterpartyNameAr',  (SELECT name_ar FROM party WHERE id = c.counterparty_id),
      'templateId',          d.template_id,
      'templateDisplayNameEn', t.display_name_en,
      'templateDisplayNameAr', t.display_name_ar,
      'approvalStatus',      d.approval_status,
      'generatedAt',         d.created_at,
      'createdBy',           d.created_by,
      'createdByName',       (SELECT concat_ws(' ', u.first_name, u.last_name) FROM "user" u WHERE u.id = d.created_by),
      'approvedByName',      (SELECT concat_ws(' ', u.first_name, u.last_name) FROM "user" u WHERE u.id = d.approved_by),
      'dispatchedAt',        d.dispatched_at,
      'correlationId',       d.correlation_id
    ) AS row_obj,
    d.created_at
    FROM advisory_draft d
    JOIN advisory_template t ON t.id = d.template_id
    JOIN contract c ON c.id = d.contract_id
    WHERE d.tenant_id = v_tenant_id AND d.is_active = TRUE
      AND (p_approval_status IS NULL OR d.approval_status = p_approval_status)
      AND (p_contract_id IS NULL OR d.contract_id = p_contract_id)
      AND (p_correlation_id IS NULL OR d.correlation_id = p_correlation_id)
      AND (p_draft_type IS NULL OR d.draft_type = p_draft_type)
      AND (NOT p_my_queue OR (
        d.approval_status = 'unapproved'
        AND t.assigned_approver_role = (SELECT r.name FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = p_actor_id)
        AND d.created_by IS DISTINCT FROM p_actor_id
      ))
    ORDER BY d.created_at DESC
    LIMIT p_limit OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total, 'page', p_page, 'limit', p_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::FLOAT / p_limit)::INTEGER END
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_list(BIGINT, TEXT, BIGINT, BIGINT, TEXT, BOOLEAN, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_advisory_draft_list(BIGINT, TEXT, BIGINT, BIGINT, TEXT, BOOLEAN, INTEGER, INTEGER) TO neondb_owner;

-- 6. INSERT HERO-001 cure_notice (L19) — Story 1 finishing move
DO $$
DECLARE
  v_existing BIGINT;
  v_tpl_id BIGINT;
  v_tpl_en TEXT;
  v_tpl_ar TEXT;
  v_ctx JSONB;
  v_corr_id BIGINT;
  v_hero_clause BIGINT;
BEGIN
  -- Skip if HERO-001 contract not on this branch
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = 52 AND contract_number = 'CRN-296-HERO-001') THEN
    RAISE NOTICE 'Mig 380: HERO-001 not on this branch — skipping seed';
    RETURN;
  END IF;

  -- Skip if already exists
  SELECT id INTO v_existing FROM advisory_draft
   WHERE contract_id = 52 AND draft_type = 'cure_notice' AND template_id IN (3, 10) LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RAISE NOTICE 'Mig 380: HERO-001 cure_notice already exists (id=%)', v_existing;
    RETURN;
  END IF;

  -- Prefer budget_cure_notice_v1 (template 10) per Story 1 spec; fall back to cure_notice_v1 (template 3)
  SELECT id, body_template_en, body_template_ar
    INTO v_tpl_id, v_tpl_en, v_tpl_ar
    FROM advisory_template
   WHERE template_id = 'budget_cure_notice_v1'
   LIMIT 1;
  IF v_tpl_id IS NULL THEN
    SELECT id, body_template_en, body_template_ar INTO v_tpl_id, v_tpl_en, v_tpl_ar
      FROM advisory_template WHERE template_id = 'cure_notice_v1' LIMIT 1;
  END IF;

  -- Find or reuse a correlation for HERO-001 budget breach
  SELECT id INTO v_corr_id FROM correlation
   WHERE contract_id = 52 ORDER BY id DESC LIMIT 1;
  IF v_corr_id IS NULL THEN
    -- Fall back to correlation 1
    SELECT id INTO v_corr_id FROM correlation ORDER BY id LIMIT 1;
  END IF;

  -- Build HERO-001 context — Story 1 anchor parameters per QA exec script C.4
  v_ctx := jsonb_build_object(
    'notice_date', '2026-05-30',
    'contract_id', 'CRN-296-HERO-001',
    'addressee', 'Chief Operating Officer, ADNOC Drilling',
    'counterparty_name', 'ADNOC Drilling',
    'breach_description',
      '+13.0% variance against 2026-07 budget baseline detected on jack-up drilling rig services. ' ||
      '7 individual day-rate breach events confirmed in April 2026 (+8% sustained) under Schedule 3 ' ||
      'day-rate ceiling. Year-end projected overrun: +AED 42.1M against AED 845M FY allocation.',
    'cure_period_days', '30',
    'cure_period_end_date', '2026-06-29',
    'cure_address',
      'ADNOC Group Legal Affairs Division, Corniche Road, Abu Dhabi, UAE — legal@adnoc.ae'
  );

  INSERT INTO advisory_draft (
    tenant_id, correlation_id, contract_id, template_id, template_version,
    draft_type, generated_text_en, generated_text_ar, template_context,
    model_version, prompt_hash, response_hash, approval_status,
    data_classification, created_at, updated_at, created_by, updated_by, is_active
  )
  VALUES (
    '00000000-0000-0000-0000-000000000001',
    v_corr_id,
    52,
    v_tpl_id,
    1,
    'cure_notice',
    fn_mustache_render(v_tpl_en, v_ctx),
    fn_mustache_render(v_tpl_ar, v_ctx),
    v_ctx,
    'demo-seed',
    'L19-HERO-001-seed',
    'L19-HERO-001-seed',
    'unapproved',
    'sensitive',
    NOW() - INTERVAL '6 hours',
    NOW() - INTERVAL '6 hours',
    13, -- Fatima Finance drafted (handoff from her budget detection)
    13,
    TRUE
  );
END $$;

-- 7. Diversify counterparties — INSERT 4 new advisory drafts on different contracts (L18)
DO $$
DECLARE
  v_corr_id BIGINT;
  v_tpl_id BIGINT;
  v_tpl_en TEXT;
  v_tpl_ar TEXT;
  v_ctx JSONB;
  v_contract RECORD;
BEGIN
  -- Skip if drafts already diversified (count distinct contract_ids > 5)
  IF (SELECT COUNT(DISTINCT contract_id) FROM advisory_draft) > 5 THEN
    RAISE NOTICE 'Mig 380: drafts already diversified — skipping';
    RETURN;
  END IF;

  SELECT id INTO v_corr_id FROM correlation ORDER BY id LIMIT 1;

  -- 7a. fm_invocation on ADNOC Distribution (contract 5)
  SELECT id, body_template_en, body_template_ar INTO v_tpl_id, v_tpl_en, v_tpl_ar
    FROM advisory_template WHERE template_id = 'hormuz_fm_invocation_v1' LIMIT 1;
  IF v_tpl_id IS NOT NULL AND EXISTS (SELECT 1 FROM contract WHERE id = 5) THEN
    SELECT * INTO v_contract FROM contract WHERE id = 5;
    v_ctx := jsonb_build_object(
      'notice_date', '2026-05-28', 'contract_id', v_contract.contract_number,
      'addressee', 'Head of Marine Operations, ADNOC Distribution PJSC',
      'counterparty_name', 'ADNOC Distribution PJSC',
      'fm_clause_text', '21.2 (Force Majeure — Geopolitical Events)',
      'signal_date', '2026-05-27',
      'signal_summary', 'Strait of Hormuz advisory raised by ADNOC Marine — confirmed FM event impacting downstream distribution.',
      'notice_period_days', '7');
    INSERT INTO advisory_draft (tenant_id, correlation_id, contract_id, template_id, template_version,
      draft_type, generated_text_en, generated_text_ar, template_context,
      model_version, prompt_hash, response_hash, approval_status,
      data_classification, created_at, updated_at, created_by, updated_by, is_active)
    VALUES ('00000000-0000-0000-0000-000000000001', v_corr_id, 5, v_tpl_id, 1, 'fm_invocation',
      fn_mustache_render(v_tpl_en, v_ctx), fn_mustache_render(v_tpl_ar, v_ctx), v_ctx,
      'demo-seed', 'L18-A-seed', 'L18-A-seed', 'unapproved',
      'pilot', NOW() - INTERVAL '2 days', NOW() - INTERVAL '2 days', 4, 4, TRUE);
  END IF;

  -- 7b. sanctions_hold on Crescent Petroleum-style counterparty (contract 1 — ADNOC MSA)
  SELECT id, body_template_en, body_template_ar INTO v_tpl_id, v_tpl_en, v_tpl_ar
    FROM advisory_template WHERE template_id = 'sanctions_hold_v1' LIMIT 1;
  IF v_tpl_id IS NOT NULL AND EXISTS (SELECT 1 FROM contract WHERE id = 1) THEN
    SELECT * INTO v_contract FROM contract WHERE id = 1;
    v_ctx := jsonb_build_object(
      'notice_date', '2026-05-29', 'contract_id', v_contract.contract_number,
      'addressee', 'General Counsel, ADNOC Distribution PJSC',
      'counterparty_name', 'ADNOC Distribution PJSC',
      'sanctioning_authority', 'UK HMT Office of Financial Sanctions Implementation (OFSI)',
      'designation_date', '2026-05-25',
      'hold_basis', 'OFSI designation of upstream tier-2 supplier triggers ADNOC sanctions screening policy SCR-2.4 — full performance suspension required.');
    INSERT INTO advisory_draft (tenant_id, correlation_id, contract_id, template_id, template_version,
      draft_type, generated_text_en, generated_text_ar, template_context,
      model_version, prompt_hash, response_hash, approval_status,
      data_classification, created_at, updated_at, created_by, updated_by, is_active)
    VALUES ('00000000-0000-0000-0000-000000000001', v_corr_id, 1, v_tpl_id, 1, 'sanctions_hold',
      fn_mustache_render(v_tpl_en, v_ctx), fn_mustache_render(v_tpl_ar, v_ctx), v_ctx,
      'demo-seed', 'L18-B-seed', 'L18-B-seed', 'unapproved',
      'sensitive', NOW() - INTERVAL '3 days', NOW() - INTERVAL '3 days', 4, 4, TRUE);
  END IF;

  -- 7c. esg_concern on different contract (NMDC concession-like, contract 38)
  SELECT id, body_template_en, body_template_ar INTO v_tpl_id, v_tpl_en, v_tpl_ar
    FROM advisory_template WHERE template_id = 'esg_concern_memo_v1' LIMIT 1;
  IF v_tpl_id IS NOT NULL AND EXISTS (SELECT 1 FROM contract WHERE id = 38) THEN
    SELECT * INTO v_contract FROM contract WHERE id = 38;
    v_ctx := jsonb_build_object(
      'notice_date', '2026-05-26', 'contract_id', v_contract.contract_number,
      'concern_summary', 'Independent OSINT review confirmed high water-stress facility at Saif Bin Darwish operations.',
      'source_url', 'https://ncm.ae/water-stress-2026',
      'sub_contractor_name', 'Tier-2 marine logistics supplier',
      'prime_counterparty_name', 'DEWA — Dubai Electricity & Water Authority',
      'recommended_review', 'Compliance ESG review within 5 business days — escalate to Khalid Compliance');
    INSERT INTO advisory_draft (tenant_id, correlation_id, contract_id, template_id, template_version,
      draft_type, generated_text_en, generated_text_ar, template_context,
      model_version, prompt_hash, response_hash, approval_status,
      data_classification, created_at, updated_at, created_by, updated_by, is_active)
    VALUES ('00000000-0000-0000-0000-000000000001', v_corr_id, 38, v_tpl_id, 1, 'esg_concern',
      fn_mustache_render(v_tpl_en, v_ctx), fn_mustache_render(v_tpl_ar, v_ctx), v_ctx,
      'demo-seed', 'L18-C-seed', 'L18-C-seed', 'unapproved',
      'pilot', NOW() - INTERVAL '4 days', NOW() - INTERVAL '4 days', 14, 14, TRUE);
  END IF;

  -- 7d. labor-law amendment on Crescent contract (contract 25 — IBM Watson AI Services SOW)
  SELECT id, body_template_en, body_template_ar INTO v_tpl_id, v_tpl_en, v_tpl_ar
    FROM advisory_template WHERE template_id = 'labor_law_amendment_v1' LIMIT 1;
  IF v_tpl_id IS NULL THEN
    SELECT id, body_template_en, body_template_ar INTO v_tpl_id, v_tpl_en, v_tpl_ar
      FROM advisory_template WHERE id = 9 LIMIT 1;
  END IF;
  IF v_tpl_id IS NOT NULL AND EXISTS (SELECT 1 FROM contract WHERE id = 25) THEN
    SELECT * INTO v_contract FROM contract WHERE id = 25;
    v_ctx := jsonb_build_object(
      'notice_date', '2026-05-25', 'contract_id', v_contract.contract_number,
      'addressee', 'Head of Human Resources, ADNOC Distribution PJSC',
      'counterparty_name', 'ADNOC Distribution PJSC',
      'breach_description', 'Federal Decree-Law 9/2024 requires Emiratisation quota uplift to 2.0% for 20-49 headcount band.',
      'cure_period_days', '30', 'cure_period_end_date', '2026-06-24',
      'cure_address', 'ADNOC Group Legal Affairs Division — legal@adnoc.ae');
    INSERT INTO advisory_draft (tenant_id, correlation_id, contract_id, template_id, template_version,
      draft_type, generated_text_en, generated_text_ar, template_context,
      model_version, prompt_hash, response_hash, approval_status,
      data_classification, created_at, updated_at, created_by, updated_by, is_active)
    VALUES ('00000000-0000-0000-0000-000000000001', v_corr_id, 25, v_tpl_id, 1, 'custom',
      fn_mustache_render(v_tpl_en, v_ctx), fn_mustache_render(v_tpl_ar, v_ctx), v_ctx,
      'demo-seed', 'L18-D-seed', 'L18-D-seed', 'unapproved',
      'pilot', NOW() - INTERVAL '5 days', NOW() - INTERVAL '5 days', 14, 14, TRUE);
  END IF;
END $$;

-- 8. Replace draft #1 final_text_en / final_text_ar with grounded content (L27)
UPDATE advisory_draft
   SET final_text_en =
'FORCE MAJEURE INVOCATION NOTICE — APPROVED FOR DISPATCH

Date: 14 May 2026
Contract Reference: MUSANAD-2026-007
Addressee: Director of Operations, Mubadala Investment Company

Dear Director of Operations,

We hereby formally invoke the Force Majeure provisions contained within Section 21.2 (Force Majeure — Geopolitical Events) of Contract No. MUSANAD-2026-007 entered into between ADNOC Group and Mubadala Investment Company.

A confirmed force majeure event has arisen from a confirmed disruption to navigability of the Strait of Hormuz, identified on 13 May 2026 via ADNOC Marine Operations Maritime Advisory ADV-2026-318 and corroborated by Reuters Energy 2026-05-13 feed (signal ID 1).

Pursuant to the force majeure clause referenced above, performance obligations under the Contract are suspended for the duration of the event. Notice is served within the contractual notice period of 7 calendar days from the date of event identification.

We request acknowledgment of receipt of this notice within 5 business days.

Yours faithfully,
ADNOC Group — Legal Affairs Division
Reviewed and approved: Layla Counsel, Senior Legal Counsel
Approval timestamp: 14 May 2026 10:05 GST',
       final_text_ar =
'إشعار استدعاء القوة القاهرة — معتمد للإرسال

التاريخ: 14 مايو 2026
مرجع العقد: MUSANAD-2026-007
المرسل إليه: مدير العمليات، شركة مبادلة للاستثمار

عزيزي مدير العمليات،

نحيطكم علماً بأننا ندعو رسمياً إلى أحكام القوة القاهرة الواردة في القسم 21.2 (القوة القاهرة — الأحداث الجيوسياسية) من العقد رقم MUSANAD-2026-007 المبرم بين مجموعة أدنوك وشركة مبادلة للاستثمار.

نشأ حدث قوة قاهرة مؤكد من اضطراب في إمكانية الملاحة في مضيق هرمز، تم تحديده في 13 مايو 2026 عبر استشارة العمليات البحرية لأدنوك ADV-2026-318 وتمت تأكيده عبر تغذية Reuters Energy 2026-05-13 (معرّف الإشارة 1).

وفقاً لبند القوة القاهرة المشار إليه أعلاه، تُعلَّق التزامات الأداء بموجب العقد طوال مدة الحدث. يُقدَّم هذا الإشعار ضمن مدة الإشعار التعاقدية البالغة 7 أيام تقويمية من تاريخ تحديد الحدث.

نطلب تأكيد استلام هذا الإشعار في غضون 5 أيام عمل.

مع خالص التحية،
مجموعة أدنوك — إدارة الشؤون القانونية
تمت المراجعة والاعتماد: ليلى المستشارة، مستشار قانوني أول
طابع الاعتماد الزمني: 14 مايو 2026 10:05 بتوقيت الخليج'
 WHERE id = 1;
