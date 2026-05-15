-- Migration: 275_unit7_inflight_fn_report_template_list_scheduled.sql
-- Module: M20 — CR-L Reports & Briefings (Unit 7 in-flight defect patch #2)
-- CR: CR-L
-- Date: 2026-05-15
-- Description: DEFECT-CRKL-SMOKE-1 fix.
--              report-scheduler.service.ts called fn_report_template_list(SYSTEM_ACTOR_ID=0, admin_mode=true)
--              on every */5-min rescan tick. fn_report_template_list (mig 263) is SECURITY INVOKER and
--              requires `report.template.manage`. SYSTEM_ACTOR (user_id=0) has no role / no permission, so
--              the call always raised ForbiddenError ("report.template.manage permission required") and
--              auto-scheduling of is_scheduled=true templates was completely broken.
--
--              Precedent: M14 fn_score_recompute_for_signal + M16 notification dispatcher both use
--              SECURITY DEFINER for worker-context fn_'s — that is the canonical pattern for the
--              permission-less SYSTEM_ACTOR carve-out.
--
--              This migration adds a worker-only sibling fn_report_template_list_scheduled_only() —
--              SECURITY DEFINER, STABLE, no permission check. It returns ONLY the rows the scheduler
--              cares about (is_scheduled=true AND enabled=true AND is_active=true) across ALL tenants.
--              The shape matches the ScheduledTemplate interface in the BE scheduler.
--
--              fn_report_template_list (admin-facing) is unchanged — user-facing /admin/report-templates
--              still goes through the INVOKER fn with proper permission enforcement.
--
-- Standards applied: S2-21 (REVOKE PUBLIC + GRANT neondb_owner trio in same migration).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_report_template_list_scheduled_only(
  p_now_utc TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_data JSONB;
BEGIN
  -- Cross-tenant read; no GUC required. No permission check — this fn is the
  -- DEFINER carve-out for the report scheduler worker (SYSTEM_ACTOR=0 context).
  -- p_now_utc parameter is reserved for future "next-run-within-window"
  -- filtering; today we return all scheduled-enabled rows and let node-cron
  -- in the BE handle the schedule firing.

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                  t.id,
    'tenantId',            t.tenant_id,
    'templateId',          t.template_id,
    'reportKind',          t.report_kind,
    'scheduleCron',        t.schedule_cron,
    'scheduleRecipients',  t.schedule_recipients,
    'isScheduled',         t.is_scheduled,
    'enabled',             t.enabled,
    'lastRunAt',           t.last_run_at
  ) ORDER BY t.tenant_id ASC, t.template_id ASC), '[]'::jsonb) INTO v_data
  FROM report_template t
  WHERE t.is_active    = TRUE
    AND t.enabled      = TRUE
    AND t.is_scheduled = TRUE
    AND t.schedule_cron IS NOT NULL
    AND length(trim(t.schedule_cron)) > 0;

  RETURN jsonb_build_object('data', COALESCE(v_data, '[]'::jsonb));

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_template_list_scheduled_only: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_report_template_list_scheduled_only(TIMESTAMPTZ) IS
  'Worker fn — returns is_scheduled=true AND enabled=true AND is_active=true report_template rows across ALL tenants. SECURITY DEFINER (report-scheduler.service.ts SYSTEM_ACTOR=0 context — fn_report_template_list is INVOKER + permission-gated and rejects the system actor). No permission check; cross-tenant scan. p_now_utc parameter reserved for future window-filtering. Defect mig 275 (DEFECT-CRKL-SMOKE-1).';

REVOKE EXECUTE ON FUNCTION fn_report_template_list_scheduled_only(TIMESTAMPTZ) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_list_scheduled_only(TIMESTAMPTZ) TO neondb_owner;


-- schema_migrations: slot 275 was pre-booked by 275_unit7_in_flight_defect_placeholder_2;
-- repoint the row to the real description (mig 274 precedent: ON CONFLICT DO UPDATE).
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (275, '275_unit7_inflight_fn_report_template_list_scheduled', NOW())
ON CONFLICT (version) DO UPDATE
  SET description = EXCLUDED.description,
      applied_at  = EXCLUDED.applied_at;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_template_list_scheduled_only(TIMESTAMPTZ);
-- UPDATE schema_migrations
--   SET description = '275_unit7_in_flight_defect_placeholder_2'
--  WHERE version = 275;
-- ============================================================
