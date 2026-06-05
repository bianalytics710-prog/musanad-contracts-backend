-- MIGRATION: 555_renewal_alert_send_jsonb_input.sql
-- Date: 2026-06-04
-- Description:
--   fn_contract_renewal_alert_send takes BIGINT[] as its contract-id input
--   but pg-node's default array binding does not carry the array element
--   type to Postgres, so the BE controller hit "invalid value type" on the
--   first POST. Easiest fix without modifying the shared callFunction()
--   helper: change the parameter to JSONB (pg-node auto-stringifies
--   objects/arrays of objects via JSON.stringify; for our primitive array
--   case we update the controller to JSON.stringify the IDs explicitly).
--
--   Drop the old fn signature and recreate as (BIGINT, JSONB, INTEGER, TEXT).
--   Body identical except for the v_ids conversion at the top.

BEGIN;

DROP FUNCTION IF EXISTS fn_contract_renewal_alert_send(BIGINT, BIGINT[], INTEGER, TEXT);

CREATE OR REPLACE FUNCTION fn_contract_renewal_alert_send(
  p_actor_id     BIGINT,
  p_contract_ids JSONB,
  p_window_days  INTEGER,
  p_note         TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id      UUID;
  v_ids            BIGINT[];
  v_contract_id    BIGINT;
  v_drafter_id     BIGINT;
  v_drafter_role   TEXT;
  v_contract_no    TEXT;
  v_title          TEXT;
  v_end_date       DATE;
  v_subject        TEXT;
  v_body           TEXT;
  v_event_id       BIGINT;
  v_event_ids      BIGINT[] := ARRAY[]::BIGINT[];
  v_skipped        BIGINT[] := ARRAY[]::BIGINT[];
  v_sent_count     INTEGER  := 0;
  v_skipped_count  INTEGER  := 0;
BEGIN
  IF NOT fn_current_user_has_permission('contract.renewal_alert.send') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_contract_ids IS NULL OR jsonb_typeof(p_contract_ids) <> 'array'
     OR jsonb_array_length(p_contract_ids) = 0 THEN
    RAISE EXCEPTION 'fn_contract_renewal_alert_send: no contracts'
      USING ERRCODE = '22023';
  END IF;
  IF p_window_days NOT IN (30, 60, 90) THEN
    RAISE EXCEPTION 'fn_contract_renewal_alert_send: windowDays must be 30, 60 or 90'
      USING ERRCODE = '22023';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_renewal_alert_send: tenant_context_missing'
      USING ERRCODE = '22023';
  END IF;

  SELECT array_agg((value)::text::bigint) INTO v_ids
    FROM jsonb_array_elements(p_contract_ids);

  FOREACH v_contract_id IN ARRAY v_ids
  LOOP
    SELECT c.drafted_by, c.contract_number,
           COALESCE(c.title_en, c.title_ar), c.end_date,
           r.name
      INTO v_drafter_id, v_contract_no, v_title, v_end_date, v_drafter_role
      FROM contract c
      LEFT JOIN "user" du ON du.id = c.drafted_by
      LEFT JOIN role r ON r.id = du.role_id AND r.is_active = TRUE
     WHERE c.id = v_contract_id
       AND c.tenant_id = v_tenant_id
       AND c.is_active = TRUE;

    IF NOT FOUND OR v_drafter_id IS NULL
       OR v_drafter_role IN ('platform_admin', 'Super Admin') THEN
      v_skipped := v_skipped || v_contract_id;
      v_skipped_count := v_skipped_count + 1;
      CONTINUE;
    END IF;

    v_subject := 'Renewal alert: ' || COALESCE(v_contract_no, 'contract') ||
                 ' expires in ' || p_window_days || ' days';
    v_body :=
      'An executive has flagged this contract for renewal action.' ||
      E'\n\nContract: ' || COALESCE(v_contract_no, '—') ||
      E'\nTitle: '     || COALESCE(v_title, '—') ||
      E'\nEnd date: '  || COALESCE(v_end_date::text, '—') ||
      E'\nWindow: next ' || p_window_days || ' days' ||
      CASE
        WHEN p_note IS NOT NULL AND length(trim(p_note)) > 0
        THEN E'\n\nNote from executive:\n' || trim(p_note)
        ELSE ''
      END;

    INSERT INTO contract_renewal_alert_event (
      tenant_id, contract_id, window_days,
      escalated_by_user_id, notified_user_ids, notification_count,
      note, created_at, created_by, is_active
    ) VALUES (
      v_tenant_id, v_contract_id, p_window_days,
      p_actor_id, ARRAY[v_drafter_id]::BIGINT[], 0,
      p_note, NOW(), p_actor_id, TRUE
    ) RETURNING id INTO v_event_id;

    BEGIN
      PERFORM fn_notification_send(
        p_actor_id,
        NULL::BIGINT,
        'alert',
        'in_app',
        'high',
        v_drafter_id,
        NULL::TEXT,
        jsonb_build_object(
          'subject',      v_subject,
          'bodyRendered', v_body,
          'contractId',   v_contract_id,
          'windowDays',   p_window_days,
          'eventId',      v_event_id,
          'source',       'contract.renewal_alert'
        ),
        NULL::BIGINT
      );

      UPDATE contract_renewal_alert_event
         SET notification_count = 1
       WHERE id = v_event_id;

      v_event_ids := v_event_ids || v_event_id;
      v_sent_count := v_sent_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_contract_renewal_alert_send: send to user % failed: %',
        v_drafter_id, SQLERRM;
      v_skipped := v_skipped || v_contract_id;
      v_skipped_count := v_skipped_count + 1;
    END;

    PERFORM fn_audit_log_record_v2(
      'contract', v_contract_id, 'UPDATE',
      NULL::jsonb,
      jsonb_build_object(
        'renewalAlertSent', TRUE,
        'eventId',          v_event_id,
        'windowDays',       p_window_days,
        'drafterId',        v_drafter_id,
        'actionCode',       'contract.renewal_alert.send'
      ),
      p_actor_id
    );
  END LOOP;

  RETURN jsonb_build_object(
    'sent',          v_sent_count,
    'skipped',       v_skipped_count,
    'eventIds',      v_event_ids,
    'skippedIds',    v_skipped
  );
END;
$function$;

COMMENT ON FUNCTION fn_contract_renewal_alert_send(BIGINT, JSONB, INTEGER, TEXT) IS
  'DEFINER. JSONB-input variant of mig 554 — pg-node cannot type a primitive number-array binding for BIGINT[], so the BE passes the IDs as a JSONB array which we cast inside.';
REVOKE EXECUTE ON FUNCTION fn_contract_renewal_alert_send(BIGINT, JSONB, INTEGER, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_renewal_alert_send(BIGINT, JSONB, INTEGER, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (555, '555_renewal_alert_send_jsonb_input', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
