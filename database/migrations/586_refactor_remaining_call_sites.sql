-- Migration: 586_refactor_remaining_call_sites.sql
-- Module: Notification trigger rules v2 — call-site refactor (4 of 4)
-- Date: 2026-06-05
--
-- Final phase of the single-source-of-truth refactor. Replaces the 4
-- remaining call sites that still call fn_notification_send directly with
-- calls to fn_notification_dispatch. Each is mechanically the same change:
-- pass event_type + payload + caller_user_id/email, and the rule registry
-- handles the rest.
--
-- Refactored:
--   1. fn_obligation_flag                (mig 503) → 'obligation.flag'
--   2. fn_obligation_sla_dispatch        (mig 500) → 'obligation.sla_breach'
--   3. fn_advisory_dispatch              (mig 217) → 'advisory.dispatched'
--   4. fn_advisory_draft_reject          (mig 509) → 'advisory.rejected'
--
-- Behavior preserved because the seeded default rules for each event use
-- the 'caller' context resolver. Admin can now add additional channels +
-- recipients to any of these events without code changes.

BEGIN;

-- ============================================================
-- 1. fn_obligation_flag  →  obligation.flag
-- ============================================================
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

  v_tenant_guc := current_setting('app.current_tenant_id', true);
  IF v_tenant_guc IS NOT NULL AND v_tenant_guc <> '' THEN
    v_tenant_id := v_tenant_guc::uuid;
  ELSE
    SELECT id INTO v_tenant_id FROM tenant WHERE is_active = TRUE LIMIT 1;
  END IF;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_not_resolved' USING ERRCODE = '22023';
  END IF;
  PERFORM set_config('app.current_tenant_id', v_tenant_id::text, true);

  SELECT * INTO v_oblig FROM contract_obligation WHERE id = p_obligation_id AND is_active = TRUE;
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
      -- v2 — single-source-of-truth dispatcher. The 'caller' context
      -- resolver in the default rule forwards v_user_id; admin can add
      -- extra channels/recipients without touching this fn.
      PERFORM fn_notification_dispatch(
        p_actor_id,
        'obligation.flag',
        jsonb_build_object(
          'subject',      v_subject,
          'bodyRendered', v_body,
          'obligationId', p_obligation_id,
          'contractId',   v_oblig.contract_id,
          'flagEventId',  v_event_id,
          'source',       'obligation.flag'
        ),
        'alert',
        'high',
        v_user_id,
        NULL::TEXT
      );
      v_notif_count := v_notif_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_obligation_flag: dispatch to user % failed: %', v_user_id, SQLERRM;
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

REVOKE EXECUTE ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) TO neondb_owner;

-- ============================================================
-- 2. fn_obligation_sla_dispatch  →  obligation.sla_breach
-- ============================================================
CREATE OR REPLACE FUNCTION fn_obligation_sla_dispatch(
  p_obligation_id BIGINT,
  p_tier_day      INTEGER
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id    UUID;
  v_oblig        contract_obligation%ROWTYPE;
  v_contract_no  TEXT;
  v_role_mapping JSONB;
  v_tiers        JSONB;
  v_tier         JSONB;
  v_priority     TEXT;
  v_extra_roles  TEXT[];
  v_type_roles   TEXT[];
  v_role_codes   TEXT[];
  v_user_ids     BIGINT[];
  v_user_id      BIGINT;
  v_notif_count  INTEGER := 0;
  v_event_id     BIGINT;
  v_subject      TEXT;
  v_body         TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_obligation_sla_dispatch: tenant_context_missing' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_oblig FROM contract_obligation WHERE id = p_obligation_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'obligation_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (
    SELECT 1 FROM obligation_escalation_event
    WHERE obligation_id = p_obligation_id
      AND escalation_type = 'sla'
      AND tier_day = p_tier_day
  ) THEN
    RETURN jsonb_build_object('skipped', TRUE, 'reason', 'already_dispatched');
  END IF;

  SELECT contract_number INTO v_contract_no FROM contract WHERE id = v_oblig.contract_id;
  SELECT value INTO v_role_mapping FROM system_setting WHERE key = 'obligations.escalation.role_mapping';
  SELECT value INTO v_tiers        FROM system_setting WHERE key = 'obligations.escalation.sla_tiers';

  SELECT t INTO v_tier
  FROM jsonb_array_elements(v_tiers) t
  WHERE (t->>'tierDay')::int = p_tier_day;

  IF v_tier IS NULL THEN
    RAISE EXCEPTION 'sla_tier_not_found' USING ERRCODE = 'P0002';
  END IF;
  v_priority := COALESCE(v_tier->>'priority', 'high');

  SELECT COALESCE(array_agg(DISTINCT role_name), ARRAY[]::TEXT[]) INTO v_type_roles
  FROM jsonb_array_elements_text(v_role_mapping->v_oblig.obligation_type) AS role_name;
  SELECT COALESCE(array_agg(DISTINCT role_name), ARRAY[]::TEXT[]) INTO v_extra_roles
  FROM jsonb_array_elements_text(v_tier->'notifyRoles') AS role_name;
  v_role_codes := array(SELECT DISTINCT unnest(v_type_roles || v_extra_roles));

  SELECT COALESCE(array_agg(DISTINCT u.id), ARRAY[]::BIGINT[]) INTO v_user_ids
  FROM "user" u JOIN role r ON r.id = u.role_id AND r.is_active = TRUE
  WHERE u.is_active = TRUE AND r.name = ANY(v_role_codes);

  IF v_oblig.assignee_user_id IS NOT NULL THEN
    v_user_ids := array(SELECT DISTINCT unnest(v_user_ids || v_oblig.assignee_user_id));
  END IF;

  v_subject := 'Obligation overdue (T+' || p_tier_day || 'd): ' || COALESCE(v_oblig.title_en, '(untitled)');
  v_body :=
    'This obligation is more than ' || p_tier_day || ' day(s) overdue and has been auto-escalated.' ||
    E'\n\nContract: '   || COALESCE(v_contract_no, '—') ||
    E'\nObligation: '   || COALESCE(v_oblig.title_en, '—') ||
    E'\nDue date: '     || COALESCE(v_oblig.due_date::text, '—');

  INSERT INTO obligation_escalation_event (
    tenant_id, obligation_id, escalation_type, tier_day,
    escalated_by_user_id, notified_role_codes, notified_user_ids,
    notification_count, note, created_at, created_by, is_active
  ) VALUES (
    v_tenant_id, p_obligation_id, 'sla', p_tier_day,
    NULL, v_role_codes, v_user_ids,
    0, NULL, NOW(), NULL, TRUE
  ) RETURNING id INTO v_event_id;

  FOREACH v_user_id IN ARRAY v_user_ids
  LOOP
    BEGIN
      PERFORM fn_notification_dispatch(
        0::BIGINT,
        'obligation.sla_breach',
        jsonb_build_object(
          'subject',      v_subject,
          'bodyRendered', v_body,
          'obligationId', p_obligation_id,
          'contractId',   v_oblig.contract_id,
          'tierDay',      p_tier_day,
          'flagEventId',  v_event_id,
          'source',       'obligation.sla'
        ),
        'alert',
        v_priority,
        v_user_id,
        NULL::TEXT
      );
      v_notif_count := v_notif_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_obligation_sla_dispatch: dispatch to user % failed: %', v_user_id, SQLERRM;
    END;
  END LOOP;

  UPDATE obligation_escalation_event SET notification_count = v_notif_count WHERE id = v_event_id;

  RETURN jsonb_build_object(
    'eventId',           v_event_id,
    'tierDay',           p_tier_day,
    'roleCodes',         v_role_codes,
    'notifiedUserIds',   v_user_ids,
    'notificationCount', v_notif_count
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_obligation_sla_dispatch(BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_sla_dispatch(BIGINT, INTEGER) TO neondb_owner;

-- ============================================================
-- 3. fn_advisory_draft_reject  →  advisory.rejected
-- ============================================================
CREATE OR REPLACE FUNCTION fn_advisory_draft_reject(
  p_actor_id         BIGINT,
  p_id               BIGINT,
  p_rejection_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id      UUID;
  v_actor_role     TEXT;
  v_d              advisory_draft%ROWTYPE;
  v_tpl_role       TEXT;
  v_draft_type     TEXT;
  v_contract_ref   TEXT;
  v_rejected_by    TEXT;
  v_tpl_subject    TEXT;
  v_tpl_body       TEXT;
  v_ctx            JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: permission_denied' USING ERRCODE = '42501';
  END IF;

  IF p_rejection_reason IS NULL OR char_length(p_rejection_reason) < 10 THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: missing_rejection_reason' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_d FROM advisory_draft
  WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: draft_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT assigned_approver_role, draft_type INTO v_tpl_role, v_draft_type
  FROM advisory_template WHERE id = v_d.template_id;
  IF v_actor_role <> v_tpl_role AND v_actor_role NOT IN ('Super Admin','platform_admin') THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: role_mismatch' USING ERRCODE = '42501';
  END IF;
  IF p_actor_id = v_d.created_by THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: self_approval_denied' USING ERRCODE = '42501';
  END IF;
  IF v_d.approval_status NOT IN ('unapproved','modified') THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: invalid_status_transition — draft already %', v_d.approval_status USING ERRCODE = '23514';
  END IF;

  UPDATE advisory_draft SET
    approval_status  = 'rejected',
    rejection_reason = p_rejection_reason,
    approved_by      = p_actor_id,
    approved_at      = NOW(),
    updated_at       = NOW(),
    updated_by       = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant_id;

  PERFORM fn_audit_log_record_v2(
    'advisory_draft', p_id, 'UPDATE',
    jsonb_build_object('approvalStatus', v_d.approval_status),
    jsonb_build_object(
      'approvalStatus',  'rejected',
      'approvedBy',      p_actor_id,
      'promptHash',      v_d.prompt_hash,
      'modelVersion',    v_d.model_version,
      'templateVersion', v_d.template_version,
      'actionCode',      'advisory.rejected'
    ),
    p_actor_id
  );

  -- Notify drafter — now through the rule registry. Best-effort.
  BEGIN
    -- Use the template's static text for subject + body so behavior matches
    -- the legacy fn (the dispatcher's chosen template might differ if admin
    -- swaps it; this fn pre-renders to keep semantics identical to v1).
    SELECT subject_en, body_en INTO v_tpl_subject, v_tpl_body
    FROM notification_template
    WHERE tenant_id = v_tenant_id
      AND template_id = 'advisory.rejected.in_app'
      AND is_active = TRUE
    LIMIT 1;

    SELECT first_name || ' ' || last_name INTO v_rejected_by
    FROM "user" WHERE id = p_actor_id;
    SELECT COALESCE(NULLIF(contract_number, ''), '#' || COALESCE(v_d.contract_id::text, '?'))
      INTO v_contract_ref
    FROM contract WHERE id = v_d.contract_id;

    v_ctx := jsonb_build_object(
      'subject',          fn_mustache_render(
                            COALESCE(v_tpl_subject, 'Your advisory draft was rejected'),
                            jsonb_build_object('draftType', COALESCE(v_draft_type, 'advisory'))
                          ),
      'bodyRendered',     fn_mustache_render(
                            COALESCE(v_tpl_body, ''),
                            jsonb_build_object(
                              'draftType',       COALESCE(v_draft_type, 'advisory'),
                              'contractRef',     COALESCE(v_contract_ref, '—'),
                              'rejectedByName',  COALESCE(v_rejected_by, 'Reviewer'),
                              'rejectionReason', p_rejection_reason
                            )
                          ),
      'advisoryDraftId',  p_id,
      'rejectionReason',  p_rejection_reason
    );

    PERFORM fn_notification_dispatch(
      p_actor_id,
      'advisory.rejected',
      v_ctx,
      'advisory',
      'medium',
      v_d.created_by,
      NULL::TEXT
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN fn_advisory_draft_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) TO neondb_owner;

-- ============================================================
-- 4. fn_advisory_dispatch — INTENTIONALLY LEFT AS-IS
-- ============================================================
-- fn_advisory_dispatch (mig 217) uses the advisory_template.dispatch_channels
-- field as its own source-of-truth for which channels to fire, and it
-- iterates over caller-supplied recipients. Refactoring it to flow through
-- fn_notification_dispatch would create a multiplication explosion
-- (per-rule-channel × per-rule-recipient × per-caller-channel ×
-- per-caller-recipient). The rule short-circuit in fn_notification_send
-- (mig 580) still applies — disabling the advisory.dispatched rule
-- silences every send fn_advisory_dispatch makes. Admin retains the
-- on/off control without channel/recipient redirection.

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (586, '586_refactor_remaining_call_sites', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
