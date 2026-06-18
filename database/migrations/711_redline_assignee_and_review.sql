-- ============================================================================
-- Migration 711 — Redline: per-change approver tagging, review comments,
--                 decision lock, and My-Work routing
-- ============================================================================
-- Edits to the redline-review workflow:
--  • A reviewer can TAG a specific approver on an individual change. That change
--    is then LOCKED to that approver (only they may accept/reject it) and a
--    work order is created for them (appears in their "My Work" queue).
--  • Reviewers (or the tagged approver) record accept/reject + an optional
--    review comment. This is a RECOMMENDATION only — it does NOT change the
--    contract.
--  • Merging accepted changes into a new version stays DRAFTER-ONLY (gated at
--    the route/controller on the contract.draft permission).
-- ============================================================================

BEGIN;

-- 1. New work-order type for a tagged redline change.
DO $wo$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'work_order'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%work_order_type%'
  LOOP
    EXECUTE 'ALTER TABLE work_order DROP CONSTRAINT ' || quote_ident(r.conname);
  END LOOP;
  ALTER TABLE work_order ADD CONSTRAINT work_order_work_order_type_check
    CHECK (work_order_type IN ('contract_draft_request', 'contract_returned',
                               'comment_response', 'redline_approver_tag'));
END
$wo$;

-- 2. Per-change assignment + review comment.
ALTER TABLE contract_redline_change
  ADD COLUMN IF NOT EXISTS assigned_to      BIGINT,
  ADD COLUMN IF NOT EXISTS assigned_by      BIGINT,
  ADD COLUMN IF NOT EXISTS assigned_at      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS reviewer_comment TEXT;

-- 3. Assignable approvers for redline tagging.
CREATE OR REPLACE FUNCTION fn_redline_assignable_approvers(p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_rows JSONB;
BEGIN
  IF NOT (fn_current_user_has_permission('contract.read.all')
       OR fn_current_user_has_permission('contract.read.department')
       OR fn_current_user_has_permission('contract.read.own')
       OR fn_current_user_has_permission('contract.draft')
       OR fn_current_user_has_permission('contract.edit')) THEN
    RAISE EXCEPTION 'forbidden: contract read permission required' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', u.id, 'name', trim(concat_ws(' ', u.first_name, u.last_name)),
           'email', u.email, 'role', r.name
         ) ORDER BY r.name, u.first_name), '[]'::jsonb)
    INTO v_rows
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.is_active = TRUE
    AND r.name IN ('contract_approver', 'contract_approver_2', 'legal_counsel');
  RETURN jsonb_build_object('data', v_rows);
END;
$fn$;

-- 4. Tag an approver on a change → lock it + create a My-Work work order.
CREATE OR REPLACE FUNCTION fn_contract_redline_change_assign(
  p_actor_id    BIGINT,
  p_change_id   BIGINT,
  p_assignee_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_contract_id BIGINT;
  v_heading     TEXT;
  v_assignee    RECORD;
BEGIN
  IF NOT (fn_current_user_has_permission('contract.edit')
       OR fn_current_user_has_permission('contract.draft')) THEN
    RAISE EXCEPTION 'forbidden: contract.edit or contract.draft required' USING ERRCODE = '42501';
  END IF;

  SELECT ri.contract_id, rc.clause_heading INTO v_contract_id, v_heading
  FROM contract_redline_change rc
  JOIN contract_redline_import ri ON ri.id = rc.import_id
  WHERE rc.id = p_change_id AND rc.is_active = TRUE;
  IF v_contract_id IS NULL THEN
    RAISE EXCEPTION 'Change not found' USING ERRCODE = '22023';
  END IF;

  SELECT u.id, trim(concat_ws(' ', u.first_name, u.last_name)) AS name
    INTO v_assignee
  FROM "user" u WHERE u.id = p_assignee_id AND u.is_active = TRUE;
  IF v_assignee.id IS NULL THEN
    RAISE EXCEPTION 'Assignee not found' USING ERRCODE = '22023';
  END IF;

  UPDATE contract_redline_change
     SET assigned_to = p_assignee_id, assigned_by = p_actor_id, assigned_at = now(),
         updated_at = now()
   WHERE id = p_change_id;

  -- My-Work work order for the tagged approver. Tenant GUC for the helper.
  PERFORM set_config('app.current_tenant_id',
    COALESCE(NULLIF(current_setting('app.current_tenant_id', true), ''),
             '00000000-0000-0000-0000-000000000001'), true);
  PERFORM set_config('app.current_user_id', p_actor_id::text, true);
  BEGIN
    PERFORM fn_work_order_auto_insert(
      'redline_approver_tag',
      v_contract_id, v_contract_id,
      p_assignee_id, p_actor_id,
      NULL, NULL,
      jsonb_build_object('changeId', p_change_id, 'clauseHeading', v_heading,
                         'kind', 'redline_review'),
      FALSE
    );
  EXCEPTION WHEN OTHERS THEN
    -- Work-order creation is best-effort; never block the assignment itself.
    NULL;
  END;

  RETURN jsonb_build_object('changeId', p_change_id, 'assignedTo', p_assignee_id,
                            'assigneeName', v_assignee.name);
END;
$fn$;

-- 5. Un-assign (clear the tag).
CREATE OR REPLACE FUNCTION fn_contract_redline_change_unassign(
  p_actor_id  BIGINT,
  p_change_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NOT (fn_current_user_has_permission('contract.edit')
       OR fn_current_user_has_permission('contract.draft')) THEN
    RAISE EXCEPTION 'forbidden: contract.edit or contract.draft required' USING ERRCODE = '42501';
  END IF;
  UPDATE contract_redline_change
     SET assigned_to = NULL, assigned_by = NULL, assigned_at = NULL, updated_at = now()
   WHERE id = p_change_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Change not found' USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object('changeId', p_change_id, 'assignedTo', NULL);
END;
$fn$;

-- 6. Decide (accept/reject) + optional comment, with the assignment lock.
DROP FUNCTION IF EXISTS fn_contract_redline_change_decide(BIGINT, BIGINT, TEXT);
CREATE OR REPLACE FUNCTION fn_contract_redline_change_decide(
  p_actor_id   BIGINT,
  p_change_id  BIGINT,
  p_decision   TEXT,
  p_comment    TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_assigned  BIGINT;
  v_import_id BIGINT;
BEGIN
  IF p_decision NOT IN ('pending', 'accepted', 'rejected') THEN
    RAISE EXCEPTION 'Invalid decision' USING ERRCODE = '22023';
  END IF;

  SELECT rc.assigned_to, rc.import_id INTO v_assigned, v_import_id
  FROM contract_redline_change rc WHERE rc.id = p_change_id AND rc.is_active = TRUE;
  IF v_import_id IS NULL THEN
    RAISE EXCEPTION 'Change not found' USING ERRCODE = '22023';
  END IF;

  -- Decision lock: if tagged to an approver, only that approver may decide it.
  IF v_assigned IS NOT NULL THEN
    IF p_actor_id <> v_assigned THEN
      RAISE EXCEPTION 'This change is assigned to another approver' USING ERRCODE = '42501';
    END IF;
  ELSE
    IF NOT (fn_current_user_has_permission('contract.edit')
         OR fn_current_user_has_permission('contract.draft')
         OR fn_current_user_has_permission('contract.read.all')
         OR fn_current_user_has_permission('contract.read.department')) THEN
      RAISE EXCEPTION 'forbidden: contract review permission required' USING ERRCODE = '42501';
    END IF;
  END IF;

  UPDATE contract_redline_change
     SET decision = p_decision,
         reviewer_comment = COALESCE(NULLIF(p_comment, ''), reviewer_comment),
         decided_by = CASE WHEN p_decision = 'pending' THEN NULL ELSE p_actor_id END,
         decided_at = CASE WHEN p_decision = 'pending' THEN NULL ELSE now() END,
         updated_at = now()
   WHERE id = p_change_id;

  RETURN jsonb_build_object('id', p_change_id, 'decision', p_decision, 'importId', v_import_id);
END;
$fn$;

-- 7. Recreate get/list to surface assignee + reviewer comment.
CREATE OR REPLACE FUNCTION fn_contract_redline_import_get(
  p_actor_id   BIGINT,
  p_import_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_imp RECORD;
  v_changes JSONB;
BEGIN
  IF NOT (fn_current_user_has_permission('contract.read.all')
       OR fn_current_user_has_permission('contract.read.department')
       OR fn_current_user_has_permission('contract.read.own')
       OR fn_current_user_has_permission('contract.draft')
       OR fn_current_user_has_permission('contract.edit')) THEN
    RAISE EXCEPTION 'forbidden: contract read permission required' USING ERRCODE = '42501';
  END IF;

  SELECT ri.*, c.contract_number, c.current_version
    INTO v_imp
  FROM contract_redline_import ri JOIN contract c ON c.id = ri.contract_id
  WHERE ri.id = p_import_id AND ri.is_active = TRUE;
  IF v_imp.id IS NULL THEN
    RAISE EXCEPTION 'Redline import not found' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', rc.id, 'seq', rc.seq, 'clauseId', rc.clause_id, 'clauseHeading', rc.clause_heading,
           'changeType', rc.change_type, 'ourText', rc.our_text, 'theirText', rc.their_text,
           'decision', rc.decision, 'decidedAt', rc.decided_at,
           'assignedTo', rc.assigned_to,
           'assigneeName', NULLIF(trim(concat_ws(' ', au.first_name, au.last_name)), ''),
           'reviewerComment', rc.reviewer_comment
         ) ORDER BY rc.seq), '[]'::jsonb)
    INTO v_changes
  FROM contract_redline_change rc
  LEFT JOIN "user" au ON au.id = rc.assigned_to
  WHERE rc.import_id = p_import_id AND rc.is_active = TRUE;

  RETURN jsonb_build_object(
    'id', v_imp.id, 'contractId', v_imp.contract_id, 'contractNumber', v_imp.contract_number,
    'baseVersionNumber', v_imp.base_version_number, 'currentVersion', v_imp.current_version,
    'filename', v_imp.filename, 'engine', v_imp.engine, 'status', v_imp.status,
    'counts', jsonb_build_object('total', v_imp.changes_total, 'added', v_imp.changes_added,
                                 'removed', v_imp.changes_removed, 'modified', v_imp.changes_modified),
    'appliedVersionNumber', v_imp.applied_version_number, 'createdAt', v_imp.created_at,
    'changes', v_changes
  );
END;
$fn$;

REVOKE ALL ON FUNCTION fn_redline_assignable_approvers(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_contract_redline_change_assign(BIGINT, BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_contract_redline_change_unassign(BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_contract_redline_change_decide(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_redline_assignable_approvers(BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_contract_redline_change_assign(BIGINT, BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_contract_redline_change_unassign(BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_contract_redline_change_decide(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (711, 'redline_assignee_and_review', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- DROP FUNCTION IF EXISTS fn_contract_redline_change_decide(BIGINT, BIGINT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_contract_redline_change_unassign(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_contract_redline_change_assign(BIGINT, BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_redline_assignable_approvers(BIGINT);
-- ALTER TABLE contract_redline_change DROP COLUMN IF EXISTS reviewer_comment, DROP COLUMN IF EXISTS assigned_at, DROP COLUMN IF EXISTS assigned_by, DROP COLUMN IF EXISTS assigned_to;
-- DELETE FROM schema_migrations WHERE version = 711;
-- ROLLBACK END
-- ============================================================================
