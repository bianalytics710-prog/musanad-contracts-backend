-- Migration: 429_aisha_cluster_p_delegate_candidates_fn.sql
-- Unit: Aisha Approver PM-grade audit fix pass (2026-06-01) — Cluster P (delegate UX)
-- Defect addressed:
--   A38 — Delegate modal currently asks for a raw numeric user ID
--         (placeholder "e.g. 42") which is unworkable for a demo audience.
--         Add a fn that returns the eligible delegate candidates for a
--         given approval_step so the FE can render a name+role picker
--         instead of a numeric input.
-- Behaviour:
--   - Returns users active + holding a role compatible with the step's
--     approver_role (exact match by role.name) OR — if approver_user_id
--     was set and approver_role is NULL — users holding the SAME role as
--     the assignee.
--   - Excludes the calling user (cannot delegate to self — AC-S3-04).
--   - Returns at most 50 candidates (LIMIT 50). Ordered by first_name then
--     last_name for deterministic FE rendering.
-- Test-branch-safe: returns empty result for unknown stepId / no eligible
-- candidates. Idempotent CREATE OR REPLACE.
-- Rollback: DROP FUNCTION fn_approval_delegate_candidates.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_approval_delegate_candidates(
  p_actor_id BIGINT,
  p_step_id  BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_role_name TEXT;
  v_result JSONB;
BEGIN
  -- Resolve the role required for the step. Priority:
  --   1. approver_role column on the step
  --   2. role of the directly-assigned approver_user_id
  SELECT COALESCE(ast.approver_role, r.name)
    INTO v_role_name
    FROM approval_step ast
    LEFT JOIN "user" u ON u.id = ast.approver_user_id
    LEFT JOIN role r ON r.id = u.role_id
   WHERE ast.id = p_step_id;

  IF v_role_name IS NULL THEN
    RETURN jsonb_build_object('data', '[]'::jsonb);
  END IF;

  SELECT jsonb_build_object(
           'data',
           COALESCE(jsonb_agg(jsonb_build_object(
             'id', u.id,
             'firstName', u.first_name,
             'lastName',  u.last_name,
             'email',     u.email,
             'role',      r.name
           ) ORDER BY u.first_name, u.last_name), '[]'::jsonb)
         )
    INTO v_result
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE u.is_active = TRUE
     AND r.name = v_role_name
     AND u.id <> p_actor_id
   LIMIT 50;

  RETURN v_result;
END $$;

REVOKE EXECUTE ON FUNCTION public.fn_approval_delegate_candidates(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_approval_delegate_candidates(BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_approval_delegate_candidates(BIGINT, BIGINT) IS
  'A38 (Aisha audit fix 2026-06-01) — list users eligible to receive a delegation for the given approval_step. Excludes caller. Used by GET /api/v1/approvals/:stepId/delegate-candidates so the FE can render a name+role picker instead of a numeric user ID input.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (429, 'A38 Aisha — fn_approval_delegate_candidates(actor_id, step_id)', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
--   DROP FUNCTION IF EXISTS public.fn_approval_delegate_candidates(BIGINT, BIGINT);
--   DELETE FROM schema_migrations WHERE version = 429;
-- COMMIT;
-- ROLLBACK END
