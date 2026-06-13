-- ============================================================================
-- Migration 645 — Phase C: harden risk-routing → no orphans, Tier-2 fallback
-- ============================================================================
--
-- WHY: Today the routing pipeline has two soft spots that could leave a case
-- stranded with status='open' AND assigned_role IS NULL — i.e. open work
-- that no inbox surfaces because no one owns it.
--
--   1. fn_risk_case_classify_and_route returns matched:false silently when
--      no rule matches. The case keeps whatever state the caller left it in.
--      Today rule #999 is the catch-all so this branch never fires — but if
--      that rule is ever disabled or removed, brand-new cases would land in
--      this exact orphan state. Defense in depth.
--   2. fn_risk_review_promote clears assigned_role and status to 'open'
--      BEFORE calling classify_and_route. Between the UPDATE and the
--      PERFORM the row is open + role-null. Any CHECK constraint enforcing
--      the invariant would fire mid-promote.
--
-- WHAT this migration does:
--   - Backfills any orphan rows (status='open' AND assigned_role IS NULL)
--     into status='in_review' so they surface in the Tier-2 queue rather
--     than sitting silent. Today the count is 0 — the migration is idempotent.
--   - Updates fn_risk_case_classify_and_route to set status='open' when a
--     rule matches AND the case is currently role-unassigned (currently it
--     only sets sla_hours + due_at). The status flip closes the orphan
--     window — promote's "set role=null" no longer needs to also set
--     status='open' (classify_and_route owns that transition).
--   - Updates fn_risk_review_promote to LEAVE status='in_review' while it
--     reroutes. classify_and_route flips to 'open' on a successful match;
--     if no rule matches, the case correctly stays in Tier-2 instead of
--     bouncing out as an orphan.
--   - Adds an explicit Tier-2 fallback in classify_and_route — if no rule
--     matches AND the case is currently role-unassigned, set status to
--     'in_review' with a metadata note so it shows up in Risk Triage.
--   - Adds the orphan invariant as a CHECK constraint. With the fn updates
--     above the constraint is always satisfiable.
--
-- WHAT it does NOT do:
--   - No new audit_log fan-out on dismiss. risk_case already has the
--     `audit_risk_case_changes` trigger which records every UPDATE, and the
--     fn already inserts a `risk_case_event` row of type='closed'. Adding a
--     third audit channel is redundant — Phase C is about routing tightness,
--     not audit surface.
-- ============================================================================

BEGIN;

-- ─── 1. Backfill orphans (idempotent — count is 0 today, defensive only) ──
UPDATE risk_case
   SET status     = 'in_review',
       metadata   = COALESCE(metadata, '{}'::jsonb)
                    || jsonb_build_object(
                         'tier', 2,
                         'tierReason', 'mig_645_orphan_backfill',
                         'backfilledAt', now()
                       ),
       updated_at = now()
 WHERE is_active = TRUE
   AND status = 'open'
   AND assigned_role IS NULL;

-- ─── 2. Updated classify_and_route ────────────────────────────────────────
-- - Sets status='open' when a rule matches and the case had no role.
-- - Falls back to status='in_review' when no rule matches and the case has
--   no role yet (Tier-2 capture).
-- - Idempotent for cases that already have a role: no status change.
CREATE OR REPLACE FUNCTION public.fn_risk_case_classify_and_route(p_case_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_case          RECORD;
  v_risk_type     TEXT;
  v_contract_type TEXT;
  v_rule          RECORD;
BEGIN
  SELECT * INTO v_case FROM risk_case WHERE id = p_case_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('matched', FALSE, 'reason', 'case_not_found');
  END IF;

  v_risk_type := fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                                  v_case.title, v_case.assigned_role, v_case.case_type);

  IF v_case.contract_id IS NOT NULL THEN
    SELECT contract_type INTO v_contract_type
      FROM contract WHERE id = v_case.contract_id;
  END IF;

  SELECT * INTO v_rule
    FROM risk_routing_rule
   WHERE tenant_id = v_case.tenant_id
     AND is_active = TRUE
     AND (case_type     IS NULL OR case_type     = v_case.case_type)
     AND (risk_type     IS NULL OR risk_type     = v_risk_type)
     AND (priority_min  IS NULL OR
          (CASE v_case.priority   WHEN 'critical' THEN 4 WHEN 'high' THEN 3
                                  WHEN 'medium'   THEN 2 WHEN 'low'  THEN 1 ELSE 0 END)
          >=
          (CASE priority_min       WHEN 'critical' THEN 4 WHEN 'high' THEN 3
                                  WHEN 'medium'   THEN 2 WHEN 'low'  THEN 1 ELSE 0 END))
     AND (contract_type IS NULL OR contract_type = v_contract_type)
   ORDER BY rule_order ASC
   LIMIT 1;

  IF NOT FOUND THEN
    -- No rule matched. If the case is currently role-unassigned and would
    -- otherwise be open, drop it into Tier-2 so it surfaces in Risk Triage.
    IF v_case.assigned_role IS NULL THEN
      UPDATE risk_case
         SET status     = 'in_review',
             metadata   = COALESCE(metadata, '{}'::jsonb)
                          || jsonb_build_object(
                               'tier', 2,
                               'tierReason', 'no_rule_matched',
                               'tieredAt', now()
                             ),
             updated_at = CURRENT_TIMESTAMP
       WHERE id = p_case_id;
    END IF;
    RETURN jsonb_build_object('matched', FALSE, 'reason', 'no_rule_matched');
  END IF;

  -- A rule matched. Apply assignment + SLA + flip status to 'open' so the
  -- specialist team sees it in their inbox. We only update when the case is
  -- currently role-unassigned so manual creates that picked a role still win.
  IF v_case.assigned_role IS NULL THEN
    UPDATE risk_case
       SET assigned_role = v_rule.assigned_role,
           sla_hours     = v_rule.sla_hours,
           due_at        = fn_demo_now() + (v_rule.sla_hours * INTERVAL '1 hour'),
           status        = 'open',
           updated_at    = CURRENT_TIMESTAMP
     WHERE id = p_case_id;
  END IF;

  RETURN jsonb_build_object(
    'matched',      TRUE,
    'ruleId',       v_rule.id,
    'ruleOrder',    v_rule.rule_order,
    'assignedRole', v_rule.assigned_role,
    'slaHours',     v_rule.sla_hours,
    'wasApplied',   v_case.assigned_role IS NULL
  );
END;
$function$;

-- ─── 3. Updated promote — no more "open + null" window ────────────────────
-- Promote now clears the role + metadata but leaves the case in 'in_review'
-- until classify_and_route succeeds. If a rule matches, classify_and_route
-- flips status to 'open'; if not, the case stays in Tier-2 (correct).
CREATE OR REPLACE FUNCTION public.fn_risk_review_promote(p_case_id BIGINT, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_case      RECORD;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.review.manage') THEN
    RAISE EXCEPTION 'risk.review.manage permission required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_case_id AND tenant_id = v_tenant_id;
  IF NOT FOUND OR NOT v_case.is_active THEN
    RAISE EXCEPTION 'case not found' USING ERRCODE = 'P0002';
  END IF;

  -- Clear executive assignment + tier marker. Status stays 'in_review' until
  -- classify_and_route succeeds; if it doesn't match a rule, the case stays
  -- in Tier-2 instead of bouncing back as an orphan.
  UPDATE risk_case
     SET assigned_role    = NULL,
         assigned_user_id = NULL,
         status           = 'in_review',
         metadata         = COALESCE(metadata, '{}'::jsonb) - 'tier' - 'tierReason' - 'suppressedReason'
                            || jsonb_build_object(
                                 'promotedFromTier2At', now(),
                                 'promotedBy',          p_actor_id
                               ),
         updated_at       = now(),
         updated_by       = p_actor_id
   WHERE id = p_case_id;

  PERFORM fn_risk_case_classify_and_route(p_case_id);

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'status_changed', p_actor_id,
            jsonb_build_object('to', 'open', 'reason', 'risk_review_promote'));

  RETURN jsonb_build_object('id', p_case_id, 'promoted', TRUE);
END;
$function$;

-- ─── 4. CHECK constraint — status='open' implies assigned_role IS NOT NULL ─
-- With the fn updates above this is always satisfiable. NOT VALID first so
-- the migration applies cleanly against historical rows that may already
-- violate it on legacy data (we backfilled the active ones in step 1, but
-- inactive closed/cancelled rows are also exempted by the constraint's
-- logical form below).
ALTER TABLE risk_case
  DROP CONSTRAINT IF EXISTS risk_case_no_orphan_open;
ALTER TABLE risk_case
  ADD  CONSTRAINT risk_case_no_orphan_open
  CHECK (status <> 'open' OR assigned_role IS NOT NULL) NOT VALID;

-- Validate now — fails loudly if any active row still violates, so we don't
-- ship the constraint in an unenforced state.
ALTER TABLE risk_case
  VALIDATE CONSTRAINT risk_case_no_orphan_open;

COMMIT;

COMMENT ON FUNCTION public.fn_risk_case_classify_and_route(BIGINT) IS
  'Phase C (mig 645, 2026-06-13) — routing fn now sets status=''open'' on a '
  'successful rule match and falls back to status=''in_review'' (Tier-2) when '
  'no rule matches and the case is role-unassigned. Closes the orphan window.';

COMMENT ON FUNCTION public.fn_risk_review_promote(BIGINT, BIGINT) IS
  'Phase C (mig 645, 2026-06-13) — promote leaves status=''in_review'' while '
  're-routing so the new constraint risk_case_no_orphan_open is never violated '
  'mid-operation. classify_and_route owns the status->open transition.';

COMMENT ON CONSTRAINT risk_case_no_orphan_open ON risk_case IS
  'Phase C invariant: a case in status=open must always have an assigned_role. '
  'No silent orphans. in_review/closed/snoozed rows may keep NULL roles.';
