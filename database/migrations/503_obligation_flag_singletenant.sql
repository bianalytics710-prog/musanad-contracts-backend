-- MIGRATION: 503_obligation_flag_singletenant.sql
-- Date: 2026-06-03
-- Description: /api/v1/obligations is mounted WITHOUT rls.middleware, so the
--              app.current_tenant_id GUC is empty when fn_obligation_flag runs
--              via the route. fn_obligation_sla_dispatch hits the same GUC
--              via the worker (which DOES set it). Both fn_'s now fall back to
--              tenant LIMIT 1 if the GUC is empty — matching single-tenant
--              deployment semantics. Multi-tenant refactor would add RLS
--              middleware + remove the fallback.

BEGIN;

CREATE OR REPLACE FUNCTION fn_obligation_flag(
  p_actor_id      BIGINT,
  p_obligation_id BIGINT,
  p_note          TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id     UUID;
  v_tenant_guc    TEXT;
  v_role_mapping  JSONB;
  v_oblig         contract_obligation%ROWTYPE;
  v_role_codes    TEXT[];
  v_user_ids      BIGINT[];
  v_user_id       BIGINT;
  v_notif_count   INTEGER := 0;
  v_event_id      BIGINT;
  v_contract_no   TEXT;
  v_subject       TEXT;
  v_body          TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('obligation.flag') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- Resolve tenant id: prefer GUC (multi-tenant path), fall back to the only
  -- active tenant row (single-tenant deployment — obligations route doesn't
  -- set the GUC today).
  v_tenant_guc := current_setting('app.current_tenant_id', true);
  IF v_tenant_guc IS NOT NULL AND v_tenant_guc <> '' THEN
    v_tenant_id := v_tenant_guc::uuid;
  ELSE
    SELECT id INTO v_tenant_id FROM tenant WHERE is_active = TRUE LIMIT 1;
  END IF;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_not_resolved' USING ERRCODE = '22023';
  END IF;
  -- Set GUC so downstream fn_notification_send picks up the right tenant.
  PERFORM set_config('app.current_tenant_id', v_tenant_id::text, true);

  SELECT * INTO v_oblig FROM contract_obligation
   WHERE id = p_obligation_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'obligation_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT contract_number INTO v_contract_no FROM contract WHERE id = v_oblig.contract_id;

  SELECT value INTO v_role_mapping FROM system_setting WHERE key = 'obligations.escalation.role_mapping';

  IF v_role_mapping IS NULL THEN
    v_role_codes := ARRAY[]::TEXT[];
  ELSE
    SELECT COALESCE(array_agg(DISTINCT role_name), ARRAY[]::TEXT[]) INTO v_role_codes
    FROM jsonb_array_elements_text(v_role_mapping->v_oblig.obligation_type) AS role_name;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT u.id), ARRAY[]::BIGINT[]) INTO v_user_ids
  FROM "user" u
  JOIN role r ON r.id = u.role_id AND r.is_active = TRUE
  WHERE u.is_active = TRUE
    AND r.name = ANY(v_role_codes)
    AND u.id <> p_actor_id;

  IF v_oblig.assignee_user_id IS NOT NULL AND v_oblig.assignee_user_id <> p_actor_id THEN
    v_user_ids := array(SELECT DISTINCT unnest(v_user_ids || v_oblig.assignee_user_id));
  END IF;

  v_subject := 'Obligation flagged: ' || COALESCE(v_oblig.title_en, '(untitled)');
  v_body :=
    'An executive has flagged this obligation for your attention.' ||
    E'\n\nContract: '   || COALESCE(v_contract_no, '—') ||
    E'\nObligation: '   || COALESCE(v_oblig.title_en, '—') ||
    E'\nDue date: '     || COALESCE(v_oblig.due_date::text, '—') ||
    CASE WHEN p_note IS NOT NULL AND length(trim(p_note)) > 0
         THEN E'\n\nNote from executive:\n' || trim(p_note)
         ELSE ''
    END;

  INSERT INTO obligation_escalation_event (
    tenant_id, obligation_id, escalation_type, tier_day,
    escalated_by_user_id, notified_role_codes, notified_user_ids,
    notification_count, note, created_at, created_by, is_active
  ) VALUES (
    v_tenant_id, p_obligation_id, 'manual', NULL,
    p_actor_id, v_role_codes, v_user_ids,
    0, p_note, NOW(), p_actor_id, TRUE
  ) RETURNING id INTO v_event_id;

  FOREACH v_user_id IN ARRAY v_user_ids
  LOOP
    BEGIN
      PERFORM fn_notification_send(
        p_actor_id,
        NULL::BIGINT,
        'alert',
        'in_app',
        'high',
        v_user_id,
        NULL::TEXT,
        jsonb_build_object(
          'subject',      v_subject,
          'bodyRendered', v_body,
          'obligationId', p_obligation_id,
          'contractId',   v_oblig.contract_id,
          'flagEventId',  v_event_id,
          'source',       'obligation.flag'
        ),
        NULL::BIGINT
      );
      v_notif_count := v_notif_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_obligation_flag: send to user % failed: %', v_user_id, SQLERRM;
    END;
  END LOOP;

  UPDATE obligation_escalation_event SET notification_count = v_notif_count WHERE id = v_event_id;

  PERFORM fn_audit_log_record_v2(
    'contract_obligation', p_obligation_id, 'UPDATE',
    NULL::jsonb,
    jsonb_build_object(
      'flagged',           TRUE,
      'escalationEventId', v_event_id,
      'roleCodes',         v_role_codes,
      'notificationCount', v_notif_count,
      'actionCode',        'obligation.flag'
    ),
    p_actor_id
  );

  RETURN jsonb_build_object(
    'eventId',           v_event_id,
    'roleCodes',         v_role_codes,
    'notifiedUserIds',   v_user_ids,
    'notificationCount', v_notif_count
  );
END;
$function$;

COMMENT ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) IS
  'DEFINER. Executive-driven manual escalation. Tenant id sourced from GUC if set, else from tenant LIMIT 1 (single-tenant deployment). Fans in-app notifications to the type''s owner roles + assignee. Requires obligation.flag permission.';
REVOKE EXECUTE ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (503, '503_obligation_flag_singletenant', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
