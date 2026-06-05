-- Migration: 584_refactor_renewal_alert_to_dispatch.sql
-- Module: Notification trigger rules v2 — call-site refactor (1 of N)
-- Date: 2026-06-05
--
-- Refactor: fn_contract_renewal_alert_send no longer calls fn_notification_send
-- directly. It calls fn_notification_dispatch('contract.expiry_30day', ...)
-- and lets the rule registry decide who/where/how.
--
-- Identical to mig 556 except the single PERFORM line in the inner loop.
-- The 'caller' context-resolver row in the seeded default rule for
-- contract.expiry_30day preserves day-1 behavior (in-app to the drafter).
--
-- The same pattern applies to the other 4 hardcoded call sites we found in
-- Phase 2 inventory:
--   - fn_advisory_reject_notify_drafter         (mig 509) → advisory.rejected
--   - fn_obligation_flag                        (mig 503) → obligation.flag
--   - fn_obligation_sla_notify                  (mig 500) → obligation.sla_breach
--   - fn_advisory_dispatch                      (mig 217) → advisory.dispatched
-- They can be migrated incrementally with the same single-line swap (see
-- the BLOCK COMMENT below "DOCUMENTED REFACTOR PATTERN" for the recipe).
--
-- The TS worker src/workers/report-run.worker.ts is refactored in the same
-- commit by switching its db.callFunction('fn_notification_send', ...) call
-- to db.callFunction('fn_notification_dispatch', ...) — outside this SQL.

BEGIN;

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
  v_event_type     TEXT;
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

  -- Map the renewal window to the existing event_type seeds: 30/60/90 → 30d.
  -- (60/90 reuse the 30-day rule. Admin can wire dedicated event types if needed.)
  v_event_type := CASE
    WHEN p_window_days = 7  THEN 'contract.expiry_7day'
    ELSE                         'contract.expiry_30day'
  END;

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
      -- v2 — single source of truth: emit the event, let the rule registry
      -- decide channels + recipients. The seeded default rule for this
      -- event has recipient_type='context' value='caller', so the drafter
      -- still receives the in-app notification on day 1. Admin can add
      -- more recipients (e.g. role:legal_counsel) without code changes.
      PERFORM fn_notification_dispatch(
        p_actor_id,
        v_event_type,
        jsonb_build_object(
          'subject',      v_subject,
          'bodyRendered', v_body,
          'contractId',   v_contract_id,
          'windowDays',   p_window_days,
          'eventId',      v_event_id,
          'source',       'contract.renewal_alert'
        ),
        'alert',
        'high',
        v_drafter_id,    -- caller_user_id — used by the 'caller' context resolver
        NULL::TEXT
      );

      UPDATE contract_renewal_alert_event
         SET notification_count = 1
       WHERE id = v_event_id;

      v_event_ids := v_event_ids || v_event_id;
      v_sent_count := v_sent_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_contract_renewal_alert_send: dispatch failed for user %: %',
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
    'sent',       v_sent_count,
    'skipped',    v_skipped_count,
    'eventIds',   v_event_ids,
    'skippedIds', v_skipped
  );
END;
$function$;

COMMENT ON FUNCTION fn_contract_renewal_alert_send(BIGINT, JSONB, INTEGER, TEXT) IS
  'DEFINER. v2 (mig 584) — emits contract.expiry_30day/7day events via fn_notification_dispatch instead of calling fn_notification_send directly. Recipients + channels now governed by notification_rule + _channel + _recipient. Default seed preserves day-1 behavior (caller resolver → drafter).';
REVOKE EXECUTE ON FUNCTION fn_contract_renewal_alert_send(BIGINT, JSONB, INTEGER, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_renewal_alert_send(BIGINT, JSONB, INTEGER, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (584, '584_refactor_renewal_alert_to_dispatch', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- DOCUMENTED REFACTOR PATTERN — apply to remaining 4 DB call sites
-- ============================================================
-- Each of fn_advisory_reject_notify_drafter, fn_obligation_flag (singletenant
-- + multitenant variants), fn_obligation_sla_notify, fn_advisory_dispatch
-- contains ONE block matching this shape:
--
--   PERFORM fn_notification_send(
--     p_actor_id, NULL_or_template_pk, kind, channel, priority,
--     user_id, NULL_or_email, payload_jsonb, NULL_or_advisory_draft_id
--   );
--
-- Replace with:
--
--   PERFORM fn_notification_dispatch(
--     p_actor_id,
--     '<event_type_code>',       -- one of: advisory.rejected, advisory.dispatched,
--                                --          obligation.flag, obligation.sla_breach
--     payload_jsonb,
--     kind,
--     priority,
--     user_id,                   -- caller_user_id (used by 'caller' resolver)
--     NULL_or_email
--   );
--
-- The 'caller' default-seed recipient row preserves identical day-1 behavior.
-- ============================================================
