-- ============================================================================
-- Migration 648 — Phase E.1: fn_risk_review_assignee_suggest(p_role)
-- ============================================================================
-- WHY: today the Risk Triage confirm-risk modal only shows the target ROLE
-- the case would route to ("Will be assigned to: Compliance & ESG"). Per
-- locked decision E-Q1, the executive wants to see a dropdown of actual
-- PEOPLE in that role, defaulted to a suggested user, with override.
--
-- WHAT: returns the ranked list of active users in the target role,
-- ordered ascending by current active risk_case load (open / in_review /
-- snoozed). Row 1 carries `suggested=true` per locked decision E-Q2 — the
-- lightest-load user is the default.
--
-- Permission gate: risk.review.manage (same as fn_risk_review_promote).
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_risk_review_assignee_suggest(p_role TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_tenant_id UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_rows      JSONB;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.review.manage') THEN
    RAISE EXCEPTION 'risk.review.manage permission required' USING ERRCODE = '42501';
  END IF;
  IF p_role IS NULL OR p_role = '' THEN
    RAISE EXCEPTION 'p_role is required' USING ERRCODE = '22023';
  END IF;

  WITH candidates AS (
    SELECT u.id,
           u.first_name,
           u.last_name,
           u.email,
           r.name AS role_name,
           COUNT(rc.id) FILTER (
             WHERE rc.status IN ('open','in_review','snoozed')
               AND rc.is_active = TRUE
               AND rc.tenant_id = v_tenant_id
           ) AS open_cases
      FROM "user" u
      JOIN role r ON r.id = u.role_id
      LEFT JOIN risk_case rc ON rc.assigned_user_id = u.id
     WHERE u.is_active = TRUE
       AND r.is_active = TRUE
       AND r.name = p_role
     GROUP BY u.id, u.first_name, u.last_name, u.email, r.name
  ),
  ranked AS (
    SELECT c.*,
           ROW_NUMBER() OVER (ORDER BY c.open_cases ASC, c.id ASC) AS rn
      FROM candidates c
  )
  SELECT COALESCE(
    jsonb_agg(jsonb_build_object(
      'id',          rk.id::text,
      'name',        TRIM(CONCAT_WS(' ', rk.first_name, rk.last_name)),
      'email',       rk.email,
      'roleName',    rk.role_name,
      'openCases',   rk.open_cases,
      'suggested',   rk.rn = 1
    ) ORDER BY rk.rn ASC),
    '[]'::jsonb
  ) INTO v_rows
    FROM ranked rk;

  RETURN jsonb_build_object('role', p_role, 'rows', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_review_assignee_suggest(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_review_assignee_suggest(TEXT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_risk_review_assignee_suggest(TEXT) IS
  'Phase E.1 (mig 648). Returns active users in p_role ranked by ascending '
  'open risk_case load (open|in_review|snoozed). First row is flagged '
  'suggested=true so the Risk Triage confirm modal can default to the '
  'lightest-load person. Gated by risk.review.manage.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (648, 'fn_risk_review_assignee_suggest', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
