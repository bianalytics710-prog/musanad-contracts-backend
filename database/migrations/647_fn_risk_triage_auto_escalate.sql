-- ============================================================================
-- Migration 647 — Phase D: fn_risk_triage_auto_escalate (daily cron entry)
-- ============================================================================
-- Daily, the BE cron worker calls this DEFINER fn cross-tenant. It finds
-- Tier-2 cases (status='in_review' AND assigned_role IS NULL) that have been
-- sitting past `tier2AutoEscalateDays` without exec action, and:
--
--   1. Stamps metadata.tier2EscalatedAt + tier2EscalatedReason so we don't
--      re-fire on every tick — dedupe is per-case.
--   2. Records a risk_case_event of type 'tier2_auto_escalated' for audit.
--   3. Returns the case ids so the BE worker can optionally fan out a
--      notification to platform_admin + executive (handled at the BE layer
--      to avoid coupling this fn to the notification rule infrastructure).
--
-- The fn is audit-only — it does not change status or assigned_role. The
-- case stays in Tier-2 where the executive can still confirm/dismiss it; the
-- alert just makes sure no Tier-2 case rots silently.
-- ============================================================================

-- Extend risk_case_event.event_type whitelist with the new audit type before
-- the fn can use it.
ALTER TABLE risk_case_event DROP CONSTRAINT IF EXISTS risk_case_event_event_type_check;
ALTER TABLE risk_case_event
  ADD CONSTRAINT risk_case_event_event_type_check
  CHECK (event_type IN (
    'created', 'assigned', 'status_changed', 'comment_added',
    'evidence_uploaded', 'escalated', 'accepted_risk', 'snoozed',
    'closed', 'reopened',
    'tier2_auto_escalated'
  ));

CREATE OR REPLACE FUNCTION public.fn_risk_triage_auto_escalate()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_escalate_days INTEGER;
  v_now           TIMESTAMPTZ := COALESCE(fn_demo_now(), CURRENT_TIMESTAMP);
  v_case          RECORD;
  v_ids           BIGINT[]    := ARRAY[]::BIGINT[];
  v_tenant_ids    UUID[]      := ARRAY[]::UUID[];
BEGIN
  -- Read the configured threshold (default 14 days if missing / unparseable).
  SELECT NULLIF((value)::text, 'null')::INTEGER
    INTO v_escalate_days
    FROM system_setting
   WHERE key = 'tier2AutoEscalateDays'
     AND is_active = true
   LIMIT 1;
  IF v_escalate_days IS NULL OR v_escalate_days < 1 THEN
    v_escalate_days := 14;
  END IF;

  -- Find stale Tier-2 cases not already escalated. The Tier-2 marker is
  -- metadata.tier = 2 (mirrors fn_risk_review_list's filter). status can be
  -- 'in_review' OR 'open' — the executive's queue covers both buckets.
  FOR v_case IN
    SELECT id, tenant_id, title, priority, case_type
      FROM risk_case
     WHERE is_active   = TRUE
       AND status      IN ('open', 'in_review')
       AND (metadata->>'tier')::INT = 2
       AND created_at  <= v_now - (v_escalate_days * INTERVAL '1 day')
       AND COALESCE(metadata->>'tier2EscalatedAt', '') = ''
  LOOP
    -- 1. Stamp the dedupe marker on the case.
    UPDATE risk_case
       SET metadata   = COALESCE(metadata, '{}'::jsonb)
                        || jsonb_build_object(
                             'tier2EscalatedAt',     v_now,
                             'tier2EscalatedReason', 'auto_escalate_unactioned_days_threshold'
                           ),
           updated_at = v_now
     WHERE id = v_case.id;

    -- 2. Audit row in the risk_case_event timeline.
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (
      v_case.tenant_id,
      v_case.id,
      'tier2_auto_escalated',
      NULL,
      jsonb_build_object(
        'reason',        'unactioned_days_threshold',
        'thresholdDays', v_escalate_days,
        'priority',      v_case.priority
      )
    );

    -- 3. Collect for the return payload — BE worker fans out notifications.
    v_ids        := v_ids        || v_case.id;
    v_tenant_ids := v_tenant_ids || v_case.tenant_id;
  END LOOP;

  RETURN jsonb_build_object(
    'thresholdDays', v_escalate_days,
    'count',         COALESCE(array_length(v_ids, 1), 0),
    'caseIds',       to_jsonb(v_ids),
    'tenantIds',     to_jsonb(v_tenant_ids)
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.fn_risk_triage_auto_escalate() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_risk_triage_auto_escalate() TO neondb_owner;

COMMENT ON FUNCTION public.fn_risk_triage_auto_escalate() IS
  'Phase D (mig 647, 2026-06-13) — daily DEFINER fn. Marks Tier-2 cases '
  'older than tier2AutoEscalateDays as escalated (metadata.tier2EscalatedAt + '
  'risk_case_event entry). Idempotent per case; BE cron worker fans out '
  'notifications to platform_admin + executive based on the returned caseIds.';
