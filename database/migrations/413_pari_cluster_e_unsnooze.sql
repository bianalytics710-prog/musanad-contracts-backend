-- Migration: 413_pari_cluster_e_unsnooze.sql
-- Unit: Pari Procurement QA Phase 3.7 (2026-06-01) — Cluster E / P32 P33
-- Closes: P32 — Pari's single pre-existing risk case (the counterparty-concentration one)
--               was in Snoozed state, so the detail action panel only offered "Assign".
--               After mig 409 added 6 procurement cases (Open/In review/Snoozed mix),
--               the list now has actionable variety — but the legacy concentration case
--               is still Snoozed with no first-class wake-up affordance.
--         P33 — There was no inverse to fn_risk_case_snooze. Adding fn_risk_case_unsnooze
--               so the FE can wire a "Wake from snooze" button on the case detail page.
--
-- Strategy:
--   1. Create fn_risk_case_unsnooze(actor_id, case_id) — transitions snoozed → open,
--      clears snoozed_until, emits a 'unsnoozed' event, gated by assigned-user OR
--      risk.case.escalate/create permission (matches the snooze fn gate model).
--   2. Bump the pre-existing concentration case (dedupe_key='ops-seed-concentration' or
--      similar) from snoozed → open so Pari's demo experience has an actionable case.

BEGIN;

CREATE OR REPLACE FUNCTION fn_risk_case_unsnooze(
  p_actor_id BIGINT,
  p_id       BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_case risk_case%ROWTYPE;
  v_can_act BOOLEAN;
  v_evt_id BIGINT;
BEGIN
  SELECT * INTO v_case FROM risk_case WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_case.status <> 'snoozed' THEN
    RAISE EXCEPTION 'Case is not snoozed (status: %)', v_case.status USING ERRCODE = 'P0001';
  END IF;

  IF v_case.case_type IN ('correlation_alert','sla_breach') THEN
    v_can_act := fn_current_user_has_permission('risk.case.escalate') OR v_case.assigned_user_id = p_actor_id;
  ELSE
    v_can_act := fn_current_user_has_permission('risk.case.create') OR v_case.assigned_user_id = p_actor_id;
  END IF;
  IF NOT v_can_act THEN
    RAISE EXCEPTION 'permission denied for case_type %', v_case.case_type USING ERRCODE = '42501';
  END IF;

  UPDATE risk_case
     SET status        = 'open',
         snoozed_until = NULL,
         updated_at    = CURRENT_TIMESTAMP,
         updated_by    = NULLIF(p_actor_id, 0)
   WHERE id = p_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_case.tenant_id, p_id, 'unsnoozed', NULLIF(p_actor_id, 0),
            jsonb_build_object('from', 'snoozed', 'to', 'open'))
    RETURNING id INTO v_evt_id;
  PERFORM fn_audit_log_record_v2('risk_case_event', v_evt_id, 'INSERT', NULL,
    jsonb_build_object('eventType','unsnoozed'), NULLIF(p_actor_id, 0));

  RETURN fn_risk_case_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN SQLSTATE 'P0001' THEN RAISE;
  WHEN SQLSTATE 'P0002' THEN RAISE;
  WHEN SQLSTATE '42501' THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_unsnooze: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_risk_case_unsnooze(BIGINT, BIGINT) IS
  'Wake a snoozed case (status snoozed → open, clears snoozed_until). Same gate as fn_risk_case_snooze.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_unsnooze(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_unsnooze(BIGINT, BIGINT) TO neondb_owner;

-- ── Demo data: wake Pari's pre-existing concentration case ──
-- Original "Counterparty concentration > 18%" case is in snoozed; bump to open
-- so the demo lands on the actionable transition matrix.
DO $$
DECLARE
  v_case_id BIGINT;
BEGIN
  SELECT id INTO v_case_id
  FROM risk_case
  WHERE assigned_role = 'procurement_supplier_risk'
    AND status = 'snoozed'
    AND title ILIKE 'Counterparty concentration%';
  IF v_case_id IS NOT NULL THEN
    UPDATE risk_case
       SET status = 'open', snoozed_until = NULL,
           updated_at = NOW()
     WHERE id = v_case_id;
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (413, '413_pari_cluster_e_unsnooze', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
