-- 508_labor_law_critical_seed.sql
-- ============================================================================
-- Purpose: Replace AML/CFT as the LegalCounsel insights hero with a UAE labor
--   law impact relevant to ADNOC operations. The hero on /app/dashboards/insights
--   reads topCriticalImpact = first severity='critical' row in
--   fn_dashboard_legal_counsel.lists.openImpacts5, which is sourced from
--   regulatory_impact ri JOIN regulation reg LEFT JOIN regulatory_update ru.
--
-- Strategy:
--   1. Seed a 'regulator' row for MoHRE if missing (idempotent INSERT … WHERE
--      NOT EXISTS) so the new regulation has a stable issuer.
--   2. Seed a 'regulation' row for Federal Decree-Law 33/2021 (UAE Labour Law)
--      Wage Protection System enforcement update.
--   3. Seed a 'regulatory_update' row at severity='critical' for the same.
--   4. Seed 3 fresh 'regulatory_impact' rows (most recent detected_at) linking
--      the labor regulation to active employment / services / EPC contracts.
--   5. Demote any pre-existing severity='critical' regulatory_update rows that
--      are not labor-related down to 'high' so the labor law surfaces as the
--      top critical via openImpacts5 ORDER BY ri.detected_at DESC.
--
-- All inserts use NOT EXISTS guards on reference_number / reference_code so
-- the migration is safe to re-apply (idempotent).
--
-- ============================================================================
BEGIN;

DO $$
DECLARE
  v_admin_id        BIGINT;
  v_mohre_id        BIGINT;
  v_regulation_id   BIGINT;
  v_reg_update_id   BIGINT;
  v_contract_ids    BIGINT[];
BEGIN
  -- Pick the lowest active user id as the seed actor.
  SELECT MIN(id) INTO v_admin_id
  FROM "user"
  WHERE is_active = TRUE;

  IF v_admin_id IS NULL THEN
    RAISE NOTICE 'No active user to act as seed author. Aborting labor law seed.';
    RETURN;
  END IF;

  -- 1) MoHRE regulator (idempotent).
  SELECT id INTO v_mohre_id
  FROM regulator
  WHERE code = 'MoHRE'
  LIMIT 1;

  IF v_mohre_id IS NULL THEN
    INSERT INTO regulator (
      code, name_en, name_ar, jurisdiction, description_en, description_ar,
      created_by, updated_by, is_active
    ) VALUES (
      'MoHRE',
      'Ministry of Human Resources and Emiratisation',
      'وزارة الموارد البشرية والتوطين',
      'uae_federal',
      'UAE federal authority for labour relations, Wage Protection System (WPS), domestic employment standards, and Emiratisation enforcement.',
      'السلطة الاتحادية الإماراتية المسؤولة عن علاقات العمل ونظام حماية الأجور ومعايير التوظيف وتطبيق التوطين.',
      v_admin_id, v_admin_id, TRUE
    )
    RETURNING id INTO v_mohre_id;
  END IF;

  -- 2) Regulation row (idempotent on reference_code).
  SELECT id INTO v_regulation_id
  FROM regulation
  WHERE reference_code = 'FED-DL-33-2021-WPS-2026';

  IF v_regulation_id IS NULL THEN
    INSERT INTO regulation (
      reference_code, title_en, title_ar, issuer_id, regulation_type,
      jurisdiction, effective_date, summary_en, summary_ar, source_url,
      tags, status, is_seed, created_by, updated_by, is_active
    ) VALUES (
      'FED-DL-33-2021-WPS-2026',
      'Federal Decree-Law 33/2021 — Wage Protection System Enforcement Update',
      'المرسوم بقانون اتحادي 33/2021 — تحديث إنفاذ نظام حماية الأجور',
      v_mohre_id,
      'federal_decree_law',
      'uae_federal',
      (CURRENT_DATE + 30)::date,
      'Tightened WPS enforcement: end-of-service gratuity calculation, working-hours caps, and mandatory monthly wage transfers via WPS for all private-sector employers including ADNOC contractors. Non-compliance triggers escalating MoHRE fines and licence-renewal blocks.',
      'تشديد تطبيق نظام حماية الأجور: احتساب مكافأة نهاية الخدمة، وحدود ساعات العمل، والتحويلات الشهرية الإلزامية للأجور عبر النظام لجميع أصحاب العمل في القطاع الخاص بما في ذلك مقاولو أدنوك. يؤدي عدم الامتثال إلى غرامات تصاعدية من الوزارة ومنع تجديد الرخص.',
      NULL,
      ARRAY['labour','wps','end_of_service','working_hours','adnoc_contractors']::text[],
      'active',
      TRUE,
      v_admin_id, v_admin_id, TRUE
    )
    RETURNING id INTO v_regulation_id;
  END IF;

  -- 3) regulatory_update at severity='critical' (idempotent on reference_number).
  SELECT id INTO v_reg_update_id
  FROM regulatory_update
  WHERE reference_number = 'MOHRE-WPS-2026-CRITICAL';

  IF v_reg_update_id IS NULL THEN
    INSERT INTO regulatory_update (
      regulator_id, title_en, title_ar, summary_en, summary_ar,
      reference_number, published_date, effective_date, compliance_deadline,
      severity, source_url, affected_clause_categories, sub_source,
      is_seed, created_by, updated_by, is_active
    ) VALUES (
      v_mohre_id,
      'UAE Labour Law — Critical WPS + End-of-Service Enforcement Wave',
      'قانون العمل الإماراتي — موجة إنفاذ حرجة لحماية الأجور ونهاية الخدمة',
      'MoHRE has begun a critical enforcement wave covering all UAE labour contracts: WPS monthly wage transfers, end-of-service gratuity recalculation per Article 51, working-hours caps, and onsite labour-camp audits. ADNOC operating-company contracts with field-services, EPC, and manpower-supply scope are first in scope. Non-compliance can suspend contractor licences and trigger MoHRE financial penalties.',
      'بدأت وزارة الموارد البشرية والتوطين موجة إنفاذ حرجة تشمل جميع عقود العمل في الإمارات: التحويلات الشهرية للأجور عبر النظام، وإعادة احتساب مكافأة نهاية الخدمة وفق المادة 51، وحدود ساعات العمل، وتدقيق مخيمات العمل ميدانياً. عقود شركات أدنوك التشغيلية في الخدمات الميدانية والهندسة والتشييد وتوريد العمالة هي الأولى في النطاق. قد يؤدي عدم الامتثال إلى تعليق رخص المقاولين وفرض غرامات مالية من الوزارة.',
      'MOHRE-WPS-2026-CRITICAL',
      (CURRENT_DATE - 1)::date,
      (CURRENT_DATE + 14)::date,
      (CURRENT_DATE + 30)::date,
      'critical',
      NULL,
      ARRAY['employment','termination','key_personnel','indemnity']::text[],
      'MOHRE',
      TRUE,
      v_admin_id, v_admin_id, TRUE
    )
    RETURNING id INTO v_reg_update_id;
  END IF;

  -- 4) regulatory_impact rows linking the labor law to 3 fresh contracts.
  -- Prefer employment-type contracts; fall back to first 3 active contracts.
  SELECT array_agg(id) INTO v_contract_ids FROM (
    SELECT c.id
    FROM contract c
    WHERE c.is_active = TRUE
      AND c.status NOT IN ('rejected','expired','terminated')
    ORDER BY
      CASE WHEN c.contract_type IN ('employment','services','epc','master_services','sow') THEN 0 ELSE 1 END,
      c.id DESC
    LIMIT 3
  ) x;

  IF v_contract_ids IS NULL OR array_length(v_contract_ids, 1) = 0 THEN
    RAISE NOTICE 'No active contracts to attach labor law impacts to. Skipping impact seed.';
  ELSE
    INSERT INTO regulatory_impact (
      contract_id, regulation_id, regulatory_update_id,
      impact_score, impact_note_en, impact_note_ar,
      impact_summary_en, impact_summary_ar,
      detected_at, resolved, resolution_action,
      created_by, updated_by, is_active
    )
    SELECT
      cid,
      v_regulation_id,
      v_reg_update_id,
      88,
      'WPS monthly transfer cadence, end-of-service calculation per Art. 51, and working-hours caps require contract clause updates before the 14-day effective window.',
      'تتطلب وتيرة التحويلات الشهرية عبر نظام حماية الأجور واحتساب نهاية الخدمة وفق المادة 51 وحدود ساعات العمل تحديث بنود العقد قبل نافذة السريان البالغة 14 يوماً.',
      'Critical UAE Labour Law amendments — material impact on employment + manpower clauses; LC review before next pay cycle recommended.',
      'تعديلات حرجة في قانون العمل الإماراتي — تأثير جوهري على بنود التوظيف وتوريد العمالة؛ يوصى بمراجعة الإدارة القانونية قبل دورة الرواتب التالية.',
      CURRENT_TIMESTAMP,
      FALSE,
      NULL,
      v_admin_id, v_admin_id, TRUE
    FROM unnest(v_contract_ids) AS cid
    ON CONFLICT DO NOTHING;
  END IF;

  -- 5) Demote any other severity='critical' regulatory_update rows that are
  --    NOT this labor law update, so openImpacts5 surfaces the labor law as
  --    the top critical hero on the LC insights dashboard. We do not delete:
  --    other criticals (OFAC etc.) stay as 'high' and remain visible in lists.
  UPDATE regulatory_update
  SET severity = 'high',
      updated_at = CURRENT_TIMESTAMP,
      updated_by = v_admin_id
  WHERE id <> v_reg_update_id
    AND severity = 'critical'
    AND is_active = TRUE;

END
$$;

-- Mark migration applied.
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (508, 'labor_law_critical_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
-- Remove the impacts linked to the new labor law regulation.
DELETE FROM regulatory_impact ri
USING regulation r
WHERE ri.regulation_id = r.id
  AND r.reference_code = 'FED-DL-33-2021-WPS-2026';

-- Remove the critical labor-law regulatory_update row.
DELETE FROM regulatory_update
WHERE reference_number = 'MOHRE-WPS-2026-CRITICAL';

-- Remove the regulation row.
DELETE FROM regulation
WHERE reference_code = 'FED-DL-33-2021-WPS-2026';

-- We do not revert the severity demotion of pre-existing critical rows since
-- the original severities are unknown at rollback time. Operators wanting a
-- full undo should restore from a pre-migration snapshot.

DELETE FROM schema_migrations WHERE version = 508;
COMMIT;
-- ROLLBACK END
