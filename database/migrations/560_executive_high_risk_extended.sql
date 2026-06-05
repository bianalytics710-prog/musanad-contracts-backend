-- MIGRATION: 560_executive_high_risk_extended.sql
-- Date: 2026-06-05
-- Description:
--   Side-car fn fn_dashboard_executive_high_risk_extended(p_limit) for the
--   Executive dashboard ECIP section's High-risk contracts card.
--
--   The legacy inline slice in fn_dashboard_executive (migration 091)
--   returns only {id, contractNumber, titleEn, titleAr, valueAed,
--   riskScore} — not enough detail for an executive scanning the list.
--   This side-car adds:
--     - counterpartyName  — from contract.counterparty_id → party.name_en
--     - riskType          — slug from fn_classify_risk (mig 544) computed
--                           against the highest-priority OPEN/IN-REVIEW
--                           risk_case attached to the contract. NULL when
--                           no open case is attached; FE renders the muted
--                           "other" pill.
--
--   Mirrors the side-car pattern shipped in migration 558
--   (fn_dashboard_executive_counterparty_contracts) and 559
--   (fn_dashboard_executive_trends_extended) — avoids touching the giant
--   fn_dashboard_executive body.
--
--   Auth posture matches fn_dashboard_executive_critical_impacts:
--   in-body role check (executive / platform_admin / Super Admin) OR
--   fn_current_user_has_permission('insights.executive').

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_dashboard_executive_high_risk_extended(
  p_limit INTEGER DEFAULT 8
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_role     TEXT;
  v_user_id  BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  v_rows     JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive_high_risk_extended: unauthorized'
      USING ERRCODE = '42501';
  END IF;

  IF p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'fn_dashboard_executive_high_risk_extended: limit must be 1..50'
      USING ERRCODE = '22023';
  END IF;

  SELECT r.name INTO v_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = v_user_id;

  IF v_role NOT IN ('executive', 'platform_admin', 'Super Admin')
     AND NOT fn_current_user_has_permission('insights.executive') THEN
    RAISE EXCEPTION 'fn_dashboard_executive_high_risk_extended: forbidden'
      USING ERRCODE = '42501';
  END IF;

  -- Top N active contracts by ai_risk_score, enriched with counterparty
  -- name (LEFT JOIN — NULL when no counterparty linked) and the riskType
  -- slug of the dominant open risk_case (LATERAL scalar subquery — NULL
  -- when the contract has no open case).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                t.id,
    'contractNumber',    t.contract_number,
    'titleEn',           t.title_en,
    'titleAr',           t.title_ar,
    'valueAed',          t.value_aed,
    'riskScore',         t.ai_risk_score,
    'counterpartyName',  t.counterparty_name,
    'riskType',          t.risk_type
  ) ORDER BY t.ai_risk_score DESC NULLS LAST), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      c.id,
      c.contract_number,
      c.title_en,
      c.title_ar,
      c.value_aed,
      c.ai_risk_score,
      cp.name_en AS counterparty_name,
      (
        SELECT fn_classify_risk(
          NULL, NULL, NULL, NULL, NULL,
          rc.title, rc.assigned_role, rc.case_type
        )
        FROM risk_case rc
        WHERE rc.contract_id = c.id
          AND rc.is_active = TRUE
          AND rc.status NOT IN ('closed','resolved','accepted_risk','dismissed')
        ORDER BY
          CASE rc.priority
            WHEN 'critical' THEN 1
            WHEN 'high'     THEN 2
            WHEN 'medium'   THEN 3
            WHEN 'low'      THEN 4
            ELSE 5
          END,
          rc.created_at DESC
        LIMIT 1
      ) AS risk_type
    FROM contract c
    LEFT JOIN party cp ON cp.id = c.counterparty_id
    WHERE c.is_active = TRUE
      AND c.ai_risk_score IS NOT NULL
    ORDER BY c.ai_risk_score DESC NULLS LAST
    LIMIT p_limit
  ) t;

  RETURN v_rows;

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_executive_high_risk_extended: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_dashboard_executive_high_risk_extended(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_executive_high_risk_extended(INTEGER) TO neondb_owner;

COMMENT ON FUNCTION public.fn_dashboard_executive_high_risk_extended(INTEGER) IS
  'Side-car for Executive dashboard High-risk contracts card. Returns top N active contracts by ai_risk_score enriched with counterpartyName + riskType slug (from fn_classify_risk on dominant open risk_case). Auth: executive / platform_admin / Super Admin / insights.executive.';

COMMIT;
