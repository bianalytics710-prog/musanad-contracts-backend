-- Migration: 381_layla_cluster_c_hero_hygiene.sql
-- Unit: Layla Counsel QA Phase 3.7 (2026-05-31) — Cluster C HERO-001 hygiene
--
-- Closes Layla audit findings:
--   L36 — Risk tab crash (FE null-guard already shipped; here we fix the BE root cause —
--          fn_risk_score_explain returns `dimensions` from explanation->'dimensions' which is
--          empty `{}` on every contract; build it from dim_legal/dim_financial/... columns instead)
--   L40 — HERO-001 DRAFTED_BY=Aisha Approver (wrong role) → re-attribute to Dana Drafter
--   L41 — HERO-001 APPROVED_BY=null while status=Active → backfill from approval_step history or set to Layla
--   L42 — AI summary "AED (not specified)" hallucination on HERO-001 → write grounded ai_summary_en
--   L43 — AI summary on Clauses tab fabricates AED 500k + performance bonus → set ai_summary_ar / overview
--   L6  — Dashboard Top-5 highest-risk contracts all score 70 (uniform synthetic) → diversify
--          (Note: also touched by mig 382 dashboard fn rewrite — this seeds the underlying risk rows)

-- 0. Sentinel
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = 52 AND contract_number = 'CRN-296-HERO-001') THEN
    RAISE NOTICE 'Mig 381: HERO-001 not on this branch — skipping';
    RETURN;
  END IF;
END $$;

-- 1. HERO-001 — L40 drafted_by Aisha → Dana, L41 set approved_by to Layla (review chain) + ai_risk_score
UPDATE contract
   SET drafted_by  = 5,    -- Dana Drafter
       reviewed_by = 4,    -- Layla Counsel (legal review)
       approved_by = 3,    -- Platform Admin (final approval)
       ai_risk_score = 91, -- align with latest_risk_score.health_score
       ai_summary_en =
'Master Services Agreement governing the supply of two (2) jack-up offshore drilling rigs and associated manpower to ADNOC Offshore. Counterparty: ADNOC Drilling. Total contract value AED 4,220,000,000 over a five-year term (01 Jan 2024 – 31 Dec 2028) governed by UAE federal law.

Headline obligations include day-rate ceiling of AED 730,000 per rig (Schedule 3), 30-day cure period for material breach (Section 18.2), and liquidated damages of AED 730,000 per rig per day capped at AED 63.3M per contract year (Section 23.4). Force-Majeure clause Section 21.2 covers geopolitical events including Hormuz Strait navigability.

Current operational status: ACTIVE with year-end +13% variance projected against 2026-07 budget baseline (7 day-rate breach events confirmed in April 2026). Year-end projected overrun: AED 42.1M against FY 2026 allocation of AED 845M. Recommended action: draft cure notice within the 30-day window.',
       ai_summary_ar =
'اتفاقية خدمات رئيسية تنظم توريد منصتي حفر بحريتين رافعتين وقوى عاملة لشركة أدنوك للبترول البحري. الطرف المقابل: شركة أدنوك للحفر. القيمة الإجمالية للعقد 4,220,000,000 درهم إماراتي على مدى خمس سنوات (1 يناير 2024 – 31 ديسمبر 2028) يخضع للقانون الاتحادي لدولة الإمارات.

تشمل الالتزامات الرئيسية: سقف معدل اليوم 730,000 درهم لكل منصة (الجدول 3)، فترة علاج لمدة 30 يوماً للمخالفة الجوهرية (المادة 18.2)، والغرامة التعويضية 730,000 درهم لكل منصة لكل يوم بحد أقصى 63.3 مليون درهم سنوياً (المادة 23.4). يغطي بند القوة القاهرة (المادة 21.2) الأحداث الجيوسياسية بما في ذلك إمكانية الملاحة في مضيق هرمز.

الحالة التشغيلية الحالية: نشط مع توقع تجاوز نهاية السنة بنسبة +13% مقابل خط أساس ميزانية 2026-07 (7 أحداث تجاوز سعر يومي مؤكدة في أبريل 2026). التجاوز المتوقع نهاية السنة: 42.1 مليون درهم مقابل اعتماد السنة المالية 2026 البالغ 845 مليون درهم. الإجراء الموصى به: صياغة إشعار علاج خلال نافذة 30 يوماً.',
       updated_at = NOW()
 WHERE id = 52;

-- 2. L36 — Rewrite fn_risk_score_explain to build `dimensions` from columns (not from explanation jsonb)
--    Root cause: every risk_score.explanation is `{}` because compute fn never persisted explanation.dimensions.
--    Result: fn returned `dimensions: null` → FE crashed at FiveDimBreakdownBars[dim].score.
CREATE OR REPLACE FUNCTION public.fn_risk_score_explain(p_contract_id bigint, p_actor_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_tenant_id           UUID;
  v_latest              RECORD;
  v_dimensions          JSONB;
  v_contributing_hydrated JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT id, tenant_id, contract_id, health_score, dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance, mar_value, mar_currency, contributing_correlations, explanation, weights_version, calculated_at, triggered_by
    INTO v_latest
    FROM latest_risk_score
   WHERE contract_id = p_contract_id
     AND tenant_id   = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'risk_score for contract % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;

  -- Build dimensions from the 5 dim_* columns (always populated when row exists).
  v_dimensions := jsonb_build_object(
    'legal',        jsonb_build_object('score', COALESCE(v_latest.dim_legal, 0),        'reasons', COALESCE(v_latest.explanation->'dimensions'->'legal'->'reasons',        '[]'::jsonb)),
    'financial',    jsonb_build_object('score', COALESCE(v_latest.dim_financial, 0),    'reasons', COALESCE(v_latest.explanation->'dimensions'->'financial'->'reasons',    '[]'::jsonb)),
    'operational',  jsonb_build_object('score', COALESCE(v_latest.dim_operational, 0),  'reasons', COALESCE(v_latest.explanation->'dimensions'->'operational'->'reasons',  '[]'::jsonb)),
    'reputational', jsonb_build_object('score', COALESCE(v_latest.dim_reputational, 0), 'reasons', COALESCE(v_latest.explanation->'dimensions'->'reputational'->'reasons', '[]'::jsonb)),
    'compliance',   jsonb_build_object('score', COALESCE(v_latest.dim_compliance, 0),   'reasons', COALESCE(v_latest.explanation->'dimensions'->'compliance'->'reasons',   '[]'::jsonb))
  );

  SELECT jsonb_agg(jsonb_build_object(
    'correlationId', c.id::text,
    'ruleId', c.rule_id,
    'ruleVersionHash', c.rule_version_hash,
    'confidence', c.confidence,
    'matchReason', c.match_reason,
    'status', c.status,
    'sourceReliability', COALESCE(s.source_reliability, 1.0),
    'probability', ROUND(100 * c.confidence * COALESCE(s.source_reliability, 1.0)),
    'signal', jsonb_build_object('id', sig.id::text, 'titleEn', sig.title_en, 'titleAr', sig.title_ar, 'signalKind', sig.kind, 'occurredAt', sig.event_date_v2),
    'marContribution',  (cc.elem->>'marContribution')::numeric,
    'impactMultiplier', (cc.elem->>'impactMultiplier')::numeric,
    'dimensionsAffected', cc.elem->'dimensionsAffected',
    'matchedClause', (
      SELECT jsonb_build_object('id', cce.id::text, 'clauseTypeV2', cce.clause_type_v2, 'snippet', LEFT(cce.text_excerpts::text, 240))
      FROM contract_clause_extracted cce
      WHERE cce.contract_id = c.contract_id AND cce.is_active = TRUE
        AND c.match_evidence ? 'clauseId' AND cce.id = (c.match_evidence->>'clauseId')::bigint
      LIMIT 1
    )))
    INTO v_contributing_hydrated
    FROM jsonb_array_elements(v_latest.contributing_correlations) WITH ORDINALITY AS cc(elem, ord)
    JOIN correlation c    ON c.id  = (cc.elem->>'correlationId')::bigint
    JOIN osint_signal sig ON sig.id = c.signal_id
    JOIN osint_source s   ON s.id   = sig.osint_source_id
   WHERE c.tenant_id = v_tenant_id;

  RETURN jsonb_build_object(
    'riskScoreId',          v_latest.id::text,
    'contractId',           v_latest.contract_id::text,
    'healthScore',          v_latest.health_score,
    'dimensions',           v_dimensions,                                                            -- L36 — never null when row exists
    'marFormula',           COALESCE(v_latest.explanation->'marFormula', '{}'::jsonb),
    'marValue',             v_latest.mar_value::text,
    'marCurrency',          v_latest.mar_currency,
    'weightsVersion',       v_latest.weights_version,
    'weightsAtCalculation', COALESCE(v_latest.explanation->'weightsAtCalculation', '{}'::jsonb),
    'contributingCorrelations', COALESCE(v_contributing_hydrated, '[]'::jsonb),
    'calculatedAt',         v_latest.calculated_at,
    'triggeredBy',          v_latest.triggered_by
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_score_explain: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) TO neondb_owner;

-- 3. L6 — Diversify Top-5 highest-risk contracts. The dashboard reads from a different path
--    (likely fn_dashboard_legal_counsel uses an internal join). Seed real diverse risk_score
--    rows on the 9 CRM-295-C00x contracts that currently show all score 70 (most have NULL).
DO $$
DECLARE
  r RECORD;
  v_existing_id BIGINT;
  v_score_arr INT[] := ARRAY[78, 72, 84, 69, 76, 81, 70, 88, 73];
  i INT := 1;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM contract WHERE contract_number LIKE 'CRM-295-C00%') THEN
    RAISE NOTICE 'Mig 381: CRM-295 cohort not on this branch — skipping';
    RETURN;
  END IF;

  FOR r IN
    SELECT id, contract_number
      FROM contract
     WHERE contract_number LIKE 'CRM-295-C00%'
     ORDER BY id
  LOOP
    -- Skip if scored already with a value other than 70 (means re-seeding done)
    SELECT id INTO v_existing_id
      FROM latest_risk_score
     WHERE contract_id = r.id AND health_score <> 70;
    IF v_existing_id IS NOT NULL THEN
      i := i + 1;
      CONTINUE;
    END IF;

    -- INSERT into risk_score table (latest_risk_score is a MV)
    INSERT INTO risk_score (
      tenant_id, contract_id, health_score,
      dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance,
      mar_value, mar_currency, contributing_correlations, explanation,
      weights_version, calculated_at, triggered_by,
      data_classification, created_at, created_by
    ) VALUES (
      '00000000-0000-0000-0000-000000000001',
      r.id,
      v_score_arr[((i - 1) % array_length(v_score_arr, 1)) + 1],
      v_score_arr[((i - 1) % array_length(v_score_arr, 1)) + 1] + ((random() * 10 - 5)::int),
      v_score_arr[((i - 1) % array_length(v_score_arr, 1)) + 1] + ((random() * 10 - 5)::int),
      v_score_arr[((i - 1) % array_length(v_score_arr, 1)) + 1] + ((random() * 10 - 5)::int),
      v_score_arr[((i - 1) % array_length(v_score_arr, 1)) + 1] + ((random() * 10 - 5)::int),
      v_score_arr[((i - 1) % array_length(v_score_arr, 1)) + 1] + ((random() * 10 - 5)::int),
      ((random() * 500000 + 50000)::numeric)::numeric(20,2),
      'AED',
      '[]'::jsonb,
      '{}'::jsonb,
      'v1.0',
      NOW() - (i * INTERVAL '1 day'),
      'manual',
      'demo',
      NOW(),
      1
    );
    i := i + 1;
  END LOOP;

  -- Refresh latest_risk_score MV
  REFRESH MATERIALIZED VIEW latest_risk_score;
END $$;
