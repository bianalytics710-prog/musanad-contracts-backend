-- Migration: 609_drafter_recent_drafts_widen_filter.sql
-- Module: Drafter dashboard — widen Recent drafts list + add stage variety
-- Date: 2026-06-09
--
-- The FE Recent drafts widget is replacing the Value column with a Stage
-- chip (more useful for a drafter than per-row AED). But myDrafts5 is
-- filtered to status='draft' only, so every Stage cell would render the
-- same "Draft" chip — meaningless.
--
-- Widen the filter to all in-flight statuses (the same set the
-- inProgressCount KPI counts), so the Stage column actually varies row-
-- to-row. The list is still scoped to drafted_by = me and ORDER BY
-- updated_at DESC LIMIT 5, so it remains the drafter's 5 most-recent
-- in-flight contracts — just no longer restricted to pure drafts.
--
-- Everything else in fn_dashboard_drafter is byte-for-byte from
-- migration 607.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_dashboard_drafter(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id BIGINT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: unauthorized' USING ERRCODE = '42501';
  END IF;
  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;
  IF v_role IS NULL OR v_role NOT IN ('contract_drafter', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: forbidden — drafter dashboard restricted to contract_drafter, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'myDraftsCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE),
    'inProgressCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('draft','in_approval','resubmission_requested',
                         'awaiting_signature_employer','awaiting_signature_counterparty')
          AND is_active = TRUE),
    'awaitingMyActionCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('draft','resubmission_requested')
          AND is_active = TRUE),
    'readyToSendCount',
      (SELECT COUNT(*) FROM contract c
        WHERE c.drafted_by = v_user_id
          AND c.status IN ('awaiting_signature_employer','awaiting_signature_counterparty')
          AND c.is_active = TRUE),
    'myRecentlyApprovedCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('fully_signed','active')
          AND updated_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
          AND is_active = TRUE),
    'mySignedAllTimeCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('fully_signed','active','expired','terminated','amended')
          AND is_active = TRUE)
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    -- v609: widened filter so the Stage chip in the FE has real
    -- variety to show. Same set of statuses the inProgressCount KPI
    -- counts. Still ORDER BY updated_at DESC LIMIT 5.
    'myDrafts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'contractType', c.contract_type,
          'status', c.status,
          'valueAed', c.value_aed,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id
            AND status IN ('draft','in_approval','resubmission_requested',
                           'awaiting_signature_employer','awaiting_signature_counterparty')
            AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb),
    'awaitingMyAction5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id
            AND status IN ('draft','resubmission_requested')
            AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (609, '609_drafter_recent_drafts_widen_filter', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
