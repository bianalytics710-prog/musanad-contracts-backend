-- MIGRATION: 501_obligation_sla_check_singletenant_fix.sql
-- Module: Obligations — patch fn_obligation_sla_check
-- Date: 2026-06-03
-- Description: contract_obligation has no tenant_id column (single-tenant
--              ADNOC deployment). The original mig-500 version of the fn
--              projected o.tenant_id which didn't exist. Source it from
--              the tenant table instead (LIMIT 1).

BEGIN;

CREATE OR REPLACE FUNCTION fn_obligation_sla_check(
  p_limit INTEGER DEFAULT 200
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
AS $function$
DECLARE
  v_tiers      JSONB;
  v_data       JSONB;
  v_tenant_id  UUID;
BEGIN
  SELECT value INTO v_tiers FROM system_setting WHERE key = 'obligations.escalation.sla_tiers';
  IF v_tiers IS NULL THEN
    RETURN jsonb_build_object('candidates', '[]'::jsonb);
  END IF;

  -- Single-tenant model: pick the (only) active tenant row. Multi-tenant
  -- refactor would replace this with a per-row tenant_id projection on the
  -- contract_obligation table.
  SELECT id INTO v_tenant_id FROM tenant WHERE is_active = TRUE LIMIT 1;
  IF v_tenant_id IS NULL THEN
    RETURN jsonb_build_object('candidates', '[]'::jsonb);
  END IF;

  WITH tiers AS (
    SELECT (t->>'tierDay')::int AS tier_day
    FROM jsonb_array_elements(v_tiers) t
  ),
  due AS (
    SELECT
      o.id AS obligation_id,
      o.obligation_type,
      o.assignee_user_id,
      o.contract_id,
      o.title_en,
      o.due_date,
      (CURRENT_DATE - o.due_date)::int AS days_overdue
    FROM contract_obligation o
    WHERE o.is_active = TRUE
      AND o.status IN ('open', 'in_progress', 'overdue')
      AND o.due_date IS NOT NULL
      AND o.due_date < CURRENT_DATE
  ),
  matched AS (
    SELECT d.*, t.tier_day
    FROM due d
    JOIN tiers t ON t.tier_day <= d.days_overdue
  ),
  pending AS (
    SELECT m.*
    FROM matched m
    LEFT JOIN obligation_escalation_event ev
      ON ev.obligation_id = m.obligation_id
     AND ev.escalation_type = 'sla'
     AND ev.tier_day = m.tier_day
    WHERE ev.id IS NULL
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tenantId',       v_tenant_id,
    'obligationId',   p.obligation_id,
    'obligationType', p.obligation_type,
    'contractId',     p.contract_id,
    'assigneeUserId', p.assignee_user_id,
    'titleEn',        p.title_en,
    'dueDate',        p.due_date,
    'daysOverdue',    p.days_overdue,
    'tierDay',        p.tier_day
  )), '[]'::jsonb) INTO v_data
  FROM (SELECT * FROM pending ORDER BY days_overdue DESC, tier_day DESC LIMIT p_limit) p;

  RETURN jsonb_build_object('candidates', v_data);
END;
$function$;

COMMENT ON FUNCTION fn_obligation_sla_check(INTEGER) IS
  'DEFINER STABLE. Single-tenant — tenant_id sourced from tenant LIMIT 1. Returns pending {obligation, tier_day} pairs that have crossed an SLA tier but haven''t yet emitted an obligation_escalation_event(type=sla, tier_day=N) row.';
REVOKE EXECUTE ON FUNCTION fn_obligation_sla_check(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_sla_check(INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (501, '501_obligation_sla_check_singletenant_fix', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
