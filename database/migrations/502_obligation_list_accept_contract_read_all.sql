-- MIGRATION: 502_obligation_list_accept_contract_read_all.sql
-- Date: 2026-06-03
-- Description: fn_obligation_list permission gate accepts contract.read.all
--              too (Executive only has this perm — was previously rejected
--              with 42501 forbidden). Drafter has contract.read.department,
--              Legal has contract.edit. All three should pass now.

BEGIN;

CREATE OR REPLACE FUNCTION fn_obligation_list(
  p_actor_id    BIGINT,
  p_status      VARCHAR DEFAULT NULL,
  p_assignee_id BIGINT  DEFAULT NULL,
  p_limit       INTEGER DEFAULT 100,
  p_offset      INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $function$
DECLARE
  v_rows JSONB;
  v_total BIGINT;
  v_can_view_all BOOLEAN;
  v_role_mapping JSONB;
  v_visible_types TEXT[];
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department')
     AND NOT fn_current_user_has_permission('contract.read.all')
     AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_can_view_all := fn_current_user_has_permission('obligation.view.all');

  IF v_can_view_all THEN
    v_visible_types := NULL;
  ELSE
    SELECT value INTO v_role_mapping
    FROM system_setting WHERE key = 'obligations.escalation.role_mapping';

    IF v_role_mapping IS NULL THEN
      v_visible_types := ARRAY[]::TEXT[];
    ELSE
      SELECT COALESCE(array_agg(DISTINCT (m.obligation_type)::text), ARRAY[]::TEXT[]) INTO v_visible_types
      FROM jsonb_each(v_role_mapping) AS m(obligation_type, role_list)
      WHERE EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(m.role_list) AS role_name
        JOIN role r ON r.name = role_name AND r.is_active = TRUE
        JOIN "user" u ON u.role_id = r.id
        WHERE u.id = p_actor_id AND u.is_active = TRUE
      );
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM contract_obligation o
  WHERE o.is_active = TRUE
    AND (p_status IS NULL OR o.status = p_status)
    AND (p_assignee_id IS NULL OR o.assignee_user_id = p_assignee_id)
    AND (v_visible_types IS NULL
         OR o.obligation_type = ANY(v_visible_types)
         OR o.assignee_user_id = p_actor_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                o.id,
    'contractId',        o.contract_id,
    'contractNumber',    c.contract_number,
    'titleEn',           o.title_en,
    'titleAr',           o.title_ar,
    'descriptionEn',     o.description_en,
    'obligationType',    o.obligation_type,
    'dueDate',           o.due_date,
    'recurrence',        o.recurrence,
    'responsibleParty',  o.responsible_party,
    'assigneeUserId',    o.assignee_user_id,
    'status',            o.status,
    'completedAt',       o.completed_at,
    'createdAt',         o.created_at,
    'flaggedAt',         f.flagged_at,
    'flaggedByName',     f.flagged_by_name,
    'flaggedNote',       f.flagged_note
  ) ORDER BY (o.due_date IS NULL), o.due_date, o.id), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM contract_obligation
    WHERE is_active = TRUE
      AND (p_status IS NULL OR status = p_status)
      AND (p_assignee_id IS NULL OR assignee_user_id = p_assignee_id)
      AND (v_visible_types IS NULL
           OR obligation_type = ANY(v_visible_types)
           OR assignee_user_id = p_actor_id)
    ORDER BY (due_date IS NULL), due_date, id
    LIMIT p_limit OFFSET p_offset
  ) o
  JOIN contract c ON c.id = o.contract_id
  LEFT JOIN LATERAL (
    SELECT
      ev.created_at AS flagged_at,
      au.first_name || ' ' || au.last_name AS flagged_by_name,
      ev.note AS flagged_note
    FROM obligation_escalation_event ev
    LEFT JOIN "user" au ON au.id = ev.escalated_by_user_id
    WHERE ev.obligation_id = o.id AND ev.escalation_type = 'manual'
    ORDER BY ev.created_at DESC
    LIMIT 1
  ) f ON TRUE;

  RETURN jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset)
  );
END;
$function$;

COMMENT ON FUNCTION fn_obligation_list(BIGINT, VARCHAR, BIGINT, INTEGER, INTEGER) IS
  'INVOKER. Accepts contract.read.department / contract.read.all / contract.edit. Role-based filter unless actor holds obligation.view.all (executive + platform_admin). Surfaces last manual-flag event.';
REVOKE EXECUTE ON FUNCTION fn_obligation_list(BIGINT, VARCHAR, BIGINT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_list(BIGINT, VARCHAR, BIGINT, INTEGER, INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (502, '502_obligation_list_accept_contract_read_all', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
