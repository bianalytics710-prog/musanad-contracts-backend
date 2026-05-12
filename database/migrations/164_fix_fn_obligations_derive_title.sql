-- Migration: 164_fix_fn_obligations_derive_title.sql
-- Module: M12 / CR-D — second defect-fix on fn_obligations_derive_from_clause
--
-- DEFECT: contract_obligation.title_en is NOT NULL but the fn body's 5
--   INSERT branches only set description_en/description_ar. Surfaced after
--   migration 163 cleared the effective_date column ref — next test confirmed
--   action raised "null value in column title_en of relation contract_obligation
--   violates not-null constraint".
-- FIX: add title_en + title_ar (short clause-type labels) alongside the
--   existing description columns in every INSERT.
--
-- Verified by: POST /api/v1/clauses/:id/review with action='confirm' on the
--   seeded force_majeure clause returns 200 with derived obligation id.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_obligations_derive_from_clause(p_clause_id BIGINT, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_clause            RECORD;
  v_contract          RECORD;
  v_clause_type       TEXT;
  v_params            JSONB;
  v_obligation_ids    JSONB := '[]'::jsonb;
  v_skip_count        INTEGER := 0;
  v_new_id            BIGINT;
  v_due_date          DATE;
BEGIN
  SELECT cce.clause_type_v2, cce.parameters, cce.contract_id
  INTO   v_clause
  FROM   contract_clause_extracted cce
  WHERE  cce.id = p_clause_id AND cce.is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_clause_extracted with id % not found', p_clause_id USING ERRCODE = 'P0002';
  END IF;

  v_clause_type := v_clause.clause_type_v2;
  v_params      := v_clause.parameters;

  SELECT c.id, c.start_date
  INTO   v_contract
  FROM   contract c
  WHERE  c.id = v_clause.contract_id;

  IF v_clause_type = 'force_majeure' THEN
    IF v_params ? 'notice_period_days' THEN
      INSERT INTO contract_obligation (
        contract_id, title_en, title_ar, obligation_type, description_en, description_ar,
        responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id,
        'Force Majeure notice',
        'إشعار القوة القاهرة',
        'notice',
        'FM event notification (notice period: ' || (v_params->>'notice_period_days') || ' days)',
        '[AR] FM event notification (notice period: ' || (v_params->>'notice_period_days') || ' days)',
        'affected_party', 'none', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;

  ELSIF v_clause_type = 'term_and_renewal' THEN
    IF (v_params ? 'expiry_date') AND (v_params ? 'renewal_notice_period_days') THEN
      BEGIN
        v_due_date := (v_params->>'expiry_date')::date
                      - ((v_params->>'renewal_notice_period_days')::int * INTERVAL '1 day');
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid date/duration in term_and_renewal parameters' USING ERRCODE = '22023';
      END;
      INSERT INTO contract_obligation (
        contract_id, title_en, title_ar, obligation_type, description_en, description_ar,
        due_date, responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id,
        'Contract renewal notice',
        'إشعار تجديد العقد',
        'renewal',
        'Renewal notice due ' || v_due_date::text || ' (expiry: ' || (v_params->>'expiry_date') || ')',
        '[AR] Renewal notice due ' || v_due_date::text,
        v_due_date, 'principal', 'none', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;

  ELSIF v_clause_type = 'cure_period' THEN
    IF v_params ? 'cure_period_days' THEN
      INSERT INTO contract_obligation (
        contract_id, title_en, title_ar, obligation_type, description_en, description_ar,
        responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id,
        'Cure period',
        'فترة العلاج',
        'cure',
        'Cure period obligation (' || (v_params->>'cure_period_days') || ' days to remedy breach)',
        '[AR] Cure period obligation (' || (v_params->>'cure_period_days') || ' days to remedy breach)',
        'contractor', 'none', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;

  ELSIF v_clause_type = 'icv_in_country_value' THEN
    IF (v_params ? 'icv_reporting_period_months') AND (v_contract.start_date IS NOT NULL) THEN
      BEGIN
        v_due_date := (v_contract.start_date
          + ((v_params->>'icv_reporting_period_months')::int * INTERVAL '1 month'))::date;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid icv_reporting_period_months value' USING ERRCODE = '22023';
      END;
      INSERT INTO contract_obligation (
        contract_id, title_en, title_ar, obligation_type, description_en, description_ar,
        due_date, responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id,
        'ICV annual certification',
        'شهادة القيمة في الدولة السنوية',
        'certification',
        'ICV certification due ' || v_due_date::text || ' (reporting period: ' || (v_params->>'icv_reporting_period_months') || ' months)',
        '[AR] ICV certification due ' || v_due_date::text,
        v_due_date, 'contractor', 'annual', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;

  ELSIF v_clause_type = 'insurance' THEN
    IF v_params ? 'expiry_date_per_policy' THEN
      INSERT INTO contract_obligation (
        contract_id, title_en, title_ar, obligation_type, description_en, description_ar,
        responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id,
        'Insurance policy expiry notice',
        'إشعار انتهاء وثيقة التأمين',
        'notice',
        'Insurance policy expiry notice (expiry: ' || (v_params->>'expiry_date_per_policy') || ')',
        '[AR] Insurance policy expiry notice',
        'contractor', 'annual', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'clauseId',               p_clause_id,
    'obligationIds',          v_obligation_ids,
    'obligationsSkippedAsDup', v_skip_count
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_obligations_derive_from_clause: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_obligations_derive_from_clause(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_obligations_derive_from_clause(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations(version, description) VALUES (164, '164_fix_fn_obligations_derive_title') ON CONFLICT DO NOTHING;
