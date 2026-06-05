-- MIGRATION: 550_routing_admin_and_tier_gates.sql
-- Date: 2026-06-04
-- Description:
--   Phase B.2 — admin CRUD fns for risk_routing_rule, used by the
--   /app/admin/risk-routing page to add/edit/disable rules without
--   running migrations.
--
--   Phase C — tiered triage on auto-create:
--     - Extend risk_routing_rule with materiality_floor_aed +
--       confidence_floor so rules can tune their own gates.
--     - Extend correlation_rule with cooldown_seconds (per-(rule, contract)
--       cooldown to suppress bouncing-threshold noise).
--     - Add correlation.last_fired_at to track per-correlation evaluation
--       time for the cooldown check.
--     - Rewrite fn_risk_case_auto_create_from_correlation with Tier 1/2/3
--       branching. Tier 1 = high confidence, material contract value,
--       matching rule → role queue. Tier 2 = uncertain confidence or
--       no rule match → executive Risk Review queue. Tier 3 = severity
--       too low or confidence too low → log correlation only, no case
--       created.
--     - Longer dedup: correlation_id + 7-day rolling window via the
--       dedupe_key so re-syndicated articles don't open duplicate cases.
--     - Seed 2-3 Tier 2 cases so the executive Risk Review section has
--       content the moment the demo loads.
--     - New permission risk.review.manage, granted to executive +
--       platform_admin + Super Admin (the personas allowed to bulk
--       promote/dismiss Tier 2 cases).

BEGIN;

-- =====================================================================
-- PART 1 — Phase B.2 admin CRUD fns for risk_routing_rule
-- =====================================================================

-- fn_risk_routing_rule_list — returns all rules ordered by rule_order.
CREATE OR REPLACE FUNCTION public.fn_risk_routing_rule_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_tenant_id UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.routing.manage') THEN
    RAISE EXCEPTION 'risk.routing.manage permission required' USING ERRCODE = '42501';
  END IF;

  RETURN COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
        'id',                 r.id::text,
        'ruleOrder',          r.rule_order,
        'caseType',           r.case_type,
        'riskType',           r.risk_type,
        'priorityMin',        r.priority_min,
        'contractType',       r.contract_type,
        'assignedRole',       r.assigned_role,
        'slaHours',           r.sla_hours,
        'materialityFloorAed', r.materiality_floor_aed,
        'confidenceFloor',    r.confidence_floor,
        'description',        r.description,
        'isActive',           r.is_active,
        'updatedAt',          r.updated_at
      ) ORDER BY r.rule_order ASC)
       FROM risk_routing_rule r
      WHERE r.tenant_id = v_tenant_id),
    '[]'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_routing_rule_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_routing_rule_list() TO neondb_owner;

-- fn_risk_routing_rule_upsert — create or update one rule by id (NULL = create).
CREATE OR REPLACE FUNCTION public.fn_risk_routing_rule_upsert(
  p_id            bigint,
  p_rule_order    integer,
  p_case_type     text,
  p_risk_type     text,
  p_priority_min  text,
  p_contract_type text,
  p_assigned_role text,
  p_sla_hours     integer,
  p_materiality_floor_aed numeric,
  p_confidence_floor      numeric,
  p_description   text,
  p_is_active     boolean,
  p_actor_id      bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_id        BIGINT;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.routing.manage') THEN
    RAISE EXCEPTION 'risk.routing.manage permission required' USING ERRCODE = '42501';
  END IF;

  IF p_assigned_role IS NULL OR NOT EXISTS (SELECT 1 FROM role WHERE name = p_assigned_role AND is_active = TRUE) THEN
    RAISE EXCEPTION 'assignedRole must be a valid active role' USING ERRCODE = '22023';
  END IF;
  IF p_sla_hours IS NULL OR p_sla_hours <= 0 THEN
    RAISE EXCEPTION 'slaHours must be > 0' USING ERRCODE = '22023';
  END IF;
  IF p_priority_min IS NOT NULL AND p_priority_min NOT IN ('low','medium','high','critical') THEN
    RAISE EXCEPTION 'priorityMin must be low/medium/high/critical' USING ERRCODE = '22023';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO risk_routing_rule (
      tenant_id, rule_order, case_type, risk_type, priority_min, contract_type,
      assigned_role, sla_hours, materiality_floor_aed, confidence_floor,
      description, is_active, created_by, updated_by
    ) VALUES (
      v_tenant_id, p_rule_order,
      NULLIF(p_case_type, ''), NULLIF(p_risk_type, ''), NULLIF(p_priority_min, ''),
      NULLIF(p_contract_type, ''),
      p_assigned_role, p_sla_hours,
      p_materiality_floor_aed, p_confidence_floor,
      p_description, COALESCE(p_is_active, TRUE),
      p_actor_id, p_actor_id
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE risk_routing_rule
       SET rule_order             = p_rule_order,
           case_type              = NULLIF(p_case_type, ''),
           risk_type              = NULLIF(p_risk_type, ''),
           priority_min           = NULLIF(p_priority_min, ''),
           contract_type          = NULLIF(p_contract_type, ''),
           assigned_role          = p_assigned_role,
           sla_hours              = p_sla_hours,
           materiality_floor_aed  = p_materiality_floor_aed,
           confidence_floor       = p_confidence_floor,
           description            = p_description,
           is_active              = COALESCE(p_is_active, is_active),
           updated_at             = CURRENT_TIMESTAMP,
           updated_by             = p_actor_id
     WHERE id = p_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'rule not found' USING ERRCODE = 'P0002';
    END IF;
    v_id := p_id;
  END IF;

  RETURN jsonb_build_object('id', v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_routing_rule_upsert(bigint,integer,text,text,text,text,text,integer,numeric,numeric,text,boolean,bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_routing_rule_upsert(bigint,integer,text,text,text,text,text,integer,numeric,numeric,text,boolean,bigint) TO neondb_owner;

-- fn_risk_routing_rule_delete — soft-delete (is_active = FALSE).
CREATE OR REPLACE FUNCTION public.fn_risk_routing_rule_delete(p_id bigint, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.routing.manage') THEN
    RAISE EXCEPTION 'risk.routing.manage permission required' USING ERRCODE = '42501';
  END IF;

  UPDATE risk_routing_rule
     SET is_active = FALSE,
         updated_at = CURRENT_TIMESTAMP,
         updated_by = p_actor_id
   WHERE id = p_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rule not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object('id', p_id, 'isActive', FALSE);
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_routing_rule_delete(bigint,bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_routing_rule_delete(bigint,bigint) TO neondb_owner;

-- =====================================================================
-- PART 2 — Phase C: tier gate columns + cooldown + last_fired_at
-- =====================================================================

ALTER TABLE risk_routing_rule
  ADD COLUMN IF NOT EXISTS materiality_floor_aed NUMERIC(20,2),
  ADD COLUMN IF NOT EXISTS confidence_floor NUMERIC(4,3) DEFAULT 0.85;

COMMENT ON COLUMN risk_routing_rule.materiality_floor_aed IS
  'Optional contract value threshold (AED). A correlation that matches this '
  'rule only becomes a Tier 1 case if contract.value_aed >= materiality_floor. '
  'NULL means no threshold (any value qualifies).';

COMMENT ON COLUMN risk_routing_rule.confidence_floor IS
  'Correlation engine confidence threshold (0.0-1.0) above which an alert '
  'becomes a Tier 1 case (auto-routed). Below this floor but above 0.60 the '
  'alert becomes Tier 2 (Executive Risk Review). Default 0.85.';

ALTER TABLE correlation_rule
  ADD COLUMN IF NOT EXISTS cooldown_seconds INTEGER NOT NULL DEFAULT 86400;

COMMENT ON COLUMN correlation_rule.cooldown_seconds IS
  'Per-(rule, contract) cooldown window. The engine skips re-evaluation '
  'if last_fired_at + cooldown > now(). Default 86400 (24h). Prevents '
  'bouncing-threshold noise (e.g. Brent crosses, dips, crosses again).';

ALTER TABLE correlation
  ADD COLUMN IF NOT EXISTS last_fired_at TIMESTAMPTZ;

COMMENT ON COLUMN correlation.last_fired_at IS
  'Per-correlation cooldown anchor. Updated each time the engine evaluates '
  'this (rule, contract) pair. Compared against rule.cooldown_seconds before '
  'opening a new risk_case.';

-- Sensible defaults for the demo's 12 seeded rules ----------------------
-- All rules inherit confidence_floor 0.85; sanctions + force_majeure go
-- low on materiality (any value qualifies) since they're regulator-driven;
-- the rest gate at AED 1M.

UPDATE risk_routing_rule
   SET materiality_floor_aed = CASE
         WHEN risk_type IN ('sanctions','force_majeure','icv_local_content','regulatory_change') THEN 0
         ELSE 1000000
       END,
       confidence_floor = 0.85
 WHERE materiality_floor_aed IS NULL;

-- =====================================================================
-- PART 3 — Phase C: rewrite auto-create with Tier 1/2/3 branching
-- =====================================================================
--
-- New control flow:
--   1. Apply per-rule cooldown — skip entirely if rule fired recently
--      for this (rule, contract).
--   2. Lookup matching routing rule via fn_risk_case_classify_and_route
--      preview (no write yet).
--   3. Compute severity + confidence + contract materiality.
--   4. Tier 1: severity ∈ {high, critical} AND confidence >= rule floor
--              AND contract value >= rule materiality floor AND a rule
--              matched → INSERT + route to role queue.
--   5. Tier 2: severity ∈ {high, critical} AND confidence between 0.60
--              and rule floor (inclusive-exclusive) OR no rule matched
--              → INSERT with assigned_role = 'executive', status =
--              'in_review', metadata.tier = 2, metadata.suppressedReason.
--   6. Tier 3: severity < high OR confidence < 0.60 → no risk_case
--              created. Return {tier:3, suppressed:true}.
--
-- Cooldown updates correlation.last_fired_at regardless of tier so the
-- engine has a stable anchor.

CREATE OR REPLACE FUNCTION public.fn_risk_case_auto_create_from_correlation(p_correlation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_corr        RECORD;
  v_signal      RECORD;
  v_contract    RECORD;
  v_rule_name   TEXT;
  v_priority    TEXT;
  v_title       TEXT;
  v_dedupe      TEXT;
  v_id          BIGINT;
  v_was_new     BOOLEAN := FALSE;
  v_tier        INTEGER;
  v_suppressed_reason TEXT;
  v_materiality NUMERIC;
  v_confidence  NUMERIC;
  v_severity    TEXT;
  v_rule        RECORD;
  v_severity_rank INTEGER;
  v_cooldown    INTEGER;
BEGIN
  -- Load correlation + signal + contract + rule metadata in one shot.
  SELECT * INTO v_corr FROM correlation WHERE id = p_correlation_id;
  IF NOT FOUND OR v_corr.tenant_id IS NULL THEN
    RETURN jsonb_build_object('riskCaseId', NULL, 'tier', NULL, 'suppressed', FALSE,
                              'reason', 'correlation_not_found');
  END IF;

  SELECT * INTO v_signal FROM osint_signal WHERE id = v_corr.signal_id;
  SELECT * INTO v_contract FROM contract WHERE id = v_corr.contract_id;
  SELECT * INTO v_rule FROM correlation_rule WHERE rule_id = v_corr.rule_id LIMIT 1;
  v_rule_name := v_rule.name;
  v_cooldown := COALESCE(v_rule.cooldown_seconds, 86400);

  -- Apply per-correlation cooldown. If this correlation has already
  -- been evaluated within the cooldown window, skip.
  IF v_corr.last_fired_at IS NOT NULL
     AND v_corr.last_fired_at + (v_cooldown * INTERVAL '1 second') > now() THEN
    RETURN jsonb_build_object('riskCaseId', NULL, 'tier', 3, 'suppressed', TRUE,
                              'reason', 'cooldown_active');
  END IF;

  v_confidence := COALESCE(v_corr.confidence, 0.0);
  v_severity := COALESCE(v_signal.severity, 'low');
  v_materiality := COALESCE(v_contract.value_aed, 0);

  v_severity_rank := CASE v_severity
                       WHEN 'critical' THEN 4 WHEN 'high' THEN 3
                       WHEN 'medium'   THEN 2 WHEN 'low'  THEN 1
                       ELSE 0 END;

  -- Stamp last_fired_at so future evaluations honour the cooldown.
  UPDATE correlation SET last_fired_at = now() WHERE id = p_correlation_id;

  -- Tier 3 — severity floor (must be at least high) AND confidence floor.
  IF v_severity_rank < 3 OR v_confidence < 0.60 THEN
    RETURN jsonb_build_object('riskCaseId', NULL, 'tier', 3, 'suppressed', TRUE,
                              'reason',
                              CASE WHEN v_severity_rank < 3 THEN 'severity_below_floor'
                                   ELSE 'confidence_below_floor' END);
  END IF;

  -- Pre-classify (without writing the case yet) so we know which rule
  -- applies and can compare confidence + materiality against ITS floors.
  -- Reuse the existing classifier logic by computing risk_type up-front.
  SELECT * INTO v_rule
    FROM risk_routing_rule rr
   WHERE rr.tenant_id = v_corr.tenant_id
     AND rr.is_active = TRUE
     AND (rr.case_type     IS NULL OR rr.case_type = 'correlation_alert')
     AND (rr.risk_type     IS NULL OR rr.risk_type = fn_classify_risk(
              NULL, NULL, NULL, NULL, NULL,
              v_rule_name, NULL, 'correlation_alert'))
     AND (rr.priority_min  IS NULL)
     AND (rr.contract_type IS NULL OR rr.contract_type = v_contract.contract_type)
   ORDER BY rr.rule_order ASC
   LIMIT 1;

  -- Tier branching --------------------------------------------------
  IF v_rule.id IS NOT NULL
     AND v_confidence >= COALESCE(v_rule.confidence_floor, 0.85)
     AND v_materiality >= COALESCE(v_rule.materiality_floor_aed, 0) THEN
    v_tier := 1;
    v_suppressed_reason := NULL;
  ELSIF v_confidence >= 0.60 THEN
    v_tier := 2;
    v_suppressed_reason := CASE
      WHEN v_rule.id IS NULL THEN 'no_matching_rule'
      WHEN v_confidence < COALESCE(v_rule.confidence_floor, 0.85) THEN 'low_confidence'
      WHEN v_materiality < COALESCE(v_rule.materiality_floor_aed, 0) THEN 'below_materiality_floor'
      ELSE 'other'
    END;
  ELSE
    v_tier := 3;
    v_suppressed_reason := 'confidence_below_floor';
  END IF;

  -- Tier 3 — log correlation only, no risk_case.
  IF v_tier = 3 THEN
    RETURN jsonb_build_object('riskCaseId', NULL, 'tier', 3, 'suppressed', TRUE,
                              'reason', v_suppressed_reason);
  END IF;

  -- Priority: copied directly from the signal's severity (modulo high/critical).
  v_priority := CASE v_severity_rank
                  WHEN 4 THEN 'critical'
                  WHEN 3 THEN 'high'
                  ELSE 'medium'
                END;

  v_title := left(COALESCE(v_rule_name, v_corr.rule_id), 200);
  -- Longer dedup: signal dedup hash + contract_id + week-bucket. Re-fires
  -- of the same signal on different days update the existing case
  -- instead of opening a new one.
  v_dedupe := 'sig:' || COALESCE(v_signal.dedup_hash, v_corr.signal_id::text)
              || ':c' || COALESCE(v_corr.contract_id, 0)
              || ':' || to_char(now(), 'IYYY-IW');  -- ISO year + week

  BEGIN
    INSERT INTO risk_case (
      tenant_id, correlation_id, contract_id, case_type, priority, title, body,
      assigned_role, status, sla_hours, due_at,
      dedupe_key, metadata, created_by, updated_by
    ) VALUES (
      v_corr.tenant_id, p_correlation_id, v_corr.contract_id,
      'correlation_alert', v_priority, v_title, NULL,
      CASE WHEN v_tier = 1 THEN NULL ELSE 'executive' END,
      CASE WHEN v_tier = 1 THEN 'open' ELSE 'in_review' END,
      NULL, NULL,
      v_dedupe,
      jsonb_build_object(
        'autoCreated', TRUE,
        'autoCreateReason', 'rule_flag_true',
        'ruleId', v_corr.rule_id,
        'tier', v_tier,
        'confidence', v_confidence,
        'severity', v_severity,
        'materialityAed', v_materiality,
        'suppressedReason', v_suppressed_reason
      ),
      NULL, NULL
    ) RETURNING id INTO v_id;
    v_was_new := TRUE;
  EXCEPTION
    WHEN unique_violation THEN
      -- Re-fire within the same week-bucket — bump updated_at on the
      -- existing case instead of opening a new one.
      UPDATE risk_case
         SET updated_at = now(),
             metadata = COALESCE(metadata, '{}'::jsonb)
                        || jsonb_build_object('lastRefireAt', now())
       WHERE tenant_id = v_corr.tenant_id AND dedupe_key = v_dedupe
       RETURNING id INTO v_id;
      v_was_new := FALSE;
  END;

  IF v_was_new THEN
    -- Tier 1 — apply the routing matrix to set assigned_role + due_at.
    -- Tier 2 already has assigned_role='executive' from the INSERT above.
    IF v_tier = 1 THEN
      PERFORM fn_risk_case_classify_and_route(v_id);
    END IF;

    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
      VALUES (v_corr.tenant_id, v_id, 'created', NULL,
              jsonb_build_object('ruleId', v_corr.rule_id,
                                 'correlationId', p_correlation_id,
                                 'autoCreate', TRUE,
                                 'tier', v_tier));
    PERFORM fn_audit_log_record_v2('risk_case_event', v_id, 'INSERT', NULL,
      jsonb_build_object('eventType','created','autoCreate',TRUE,'tier',v_tier), NULL);
  END IF;

  RETURN jsonb_build_object(
    'riskCaseId', v_id,
    'wasNew',     v_was_new,
    'tier',       v_tier,
    'suppressed', FALSE,
    'reason',     v_suppressed_reason
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_auto_create_from_correlation: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

-- =====================================================================
-- PART 4 — Phase C: risk.review.manage permission + Risk Review fns
-- =====================================================================

INSERT INTO permission (code, module, action, description, is_active)
SELECT 'risk.review.manage', 'risk_cases', 'manage',
       'Promote or dismiss Tier 2 risk cases on the Executive Risk Review surface', TRUE
WHERE NOT EXISTS (SELECT 1 FROM permission WHERE code = 'risk.review.manage');

INSERT INTO role_permission (role_id, permission_id, is_active)
SELECT r.id, p.id, TRUE
  FROM role r CROSS JOIN permission p
 WHERE r.name IN ('executive','platform_admin','Super Admin')
   AND p.code = 'risk.review.manage'
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp
      WHERE rp.role_id = r.id AND rp.permission_id = p.id
   );

-- fn_risk_review_list — Top N Tier 2 cases by impact-weighted score.
CREATE OR REPLACE FUNCTION public.fn_risk_review_list(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_tenant_id UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.review.manage') THEN
    RAISE EXCEPTION 'risk.review.manage permission required' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'asOf', CURRENT_TIMESTAMP,
    'rows', COALESCE(
      (SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.impact_score DESC, x.id ASC)
         FROM (
           SELECT
             rc.id::text                                     AS id,
             rc.title                                        AS title,
             rc.priority                                     AS priority,
             rc.status                                       AS status,
             COALESCE(rc.body, '')                           AS description,
             rc.metadata->>'suppressedReason'                AS suppressed_reason,
             COALESCE((rc.metadata->>'confidence')::numeric, 0) AS confidence,
             COALESCE((rc.metadata->>'materialityAed')::numeric, 0) AS materiality_aed,
             fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                              rc.title, rc.assigned_role, rc.case_type) AS risk_type,
             rc.contract_id::text                            AS contract_id,
             c.contract_number                               AS contract_number,
             COALESCE(c.title_en, c.title_ar)                AS contract_title,
             cp.name_en                                      AS counterparty_name,
             c.value_aed                                     AS value_aed,
             c.currency                                      AS currency,
             rc.created_at                                   AS created_at,
             -- Impact score = materiality (AED) × confidence. Used to
             -- sort the queue so the highest-stakes borderline alerts
             -- bubble up.
             COALESCE((rc.metadata->>'materialityAed')::numeric, 0)
               * COALESCE((rc.metadata->>'confidence')::numeric, 0)   AS impact_score
             FROM risk_case rc
             LEFT JOIN contract c ON c.id = rc.contract_id
             LEFT JOIN party cp ON cp.id = c.counterparty_id
            WHERE rc.is_active = TRUE
              AND rc.tenant_id = v_tenant_id
              AND (rc.metadata->>'tier')::int = 2
              AND rc.status IN ('open','in_review')
            ORDER BY impact_score DESC, rc.id ASC
            LIMIT p_limit
         ) x),
      '[]'::jsonb
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_review_list(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_review_list(integer) TO neondb_owner;

-- fn_risk_review_promote — promote a Tier 2 case to Tier 1 (apply matrix,
-- transition status to 'open').
CREATE OR REPLACE FUNCTION public.fn_risk_review_promote(p_case_id bigint, p_actor_id bigint)
 RETURNS jsonb
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

  -- Clear executive assignment + tier marker, reset status, then route.
  UPDATE risk_case
     SET assigned_role = NULL,
         assigned_user_id = NULL,
         status = 'open',
         metadata = COALESCE(metadata, '{}'::jsonb) - 'tier' - 'suppressedReason'
                    || jsonb_build_object('promotedFromTier2At', now(),
                                          'promotedBy', p_actor_id),
         updated_at = now(),
         updated_by = p_actor_id
   WHERE id = p_case_id;

  PERFORM fn_risk_case_classify_and_route(p_case_id);

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'status_changed', p_actor_id,
            jsonb_build_object('to', 'open', 'reason', 'risk_review_promote'));

  RETURN jsonb_build_object('id', p_case_id, 'promoted', TRUE);
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_review_promote(bigint,bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_review_promote(bigint,bigint) TO neondb_owner;

-- fn_risk_review_dismiss — close case with no_action.
CREATE OR REPLACE FUNCTION public.fn_risk_review_dismiss(p_case_id bigint, p_actor_id bigint)
 RETURNS jsonb
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

  UPDATE risk_case
     SET status = 'closed',
         closure_outcome = 'no_action',
         closed_at = now(),
         closed_by = p_actor_id,
         metadata = COALESCE(metadata, '{}'::jsonb)
                    || jsonb_build_object('dismissedAsNoise', TRUE,
                                          'dismissedBy', p_actor_id,
                                          'dismissedAt', now()),
         updated_at = now(),
         updated_by = p_actor_id
   WHERE id = p_case_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'closed', p_actor_id,
            jsonb_build_object('outcome', 'no_action', 'reason', 'risk_review_dismiss'));

  RETURN jsonb_build_object('id', p_case_id, 'closed', TRUE);
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_review_dismiss(bigint,bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_review_dismiss(bigint,bigint) TO neondb_owner;

-- =====================================================================
-- PART 5 — Phase C: seed 3 Tier 2 cases so the Risk Review section
--                   has content the moment the demo loads.
-- =====================================================================
--
-- Each one represents a realistic borderline alert the engine wasn't
-- confident enough about to route directly to a specialist team. All
-- three land in the executive's Risk Review queue with confidence in
-- the 0.62-0.78 band.

INSERT INTO risk_case (
  tenant_id, contract_id, case_type, priority, title, body,
  assigned_role, assigned_user_id, status, sla_hours, due_at,
  dedupe_key, metadata, is_active, created_at, updated_at
)
SELECT '00000000-0000-0000-0000-000000000001'::uuid,
       v.contract_id, 'correlation_alert', v.priority, v.title, v.body,
       'executive', NULL, 'in_review', NULL, NULL,
       'review:seed:' || v.slug,
       v.metadata, TRUE,
       (now() - (v.age_hours * INTERVAL '1 hour')),
       (now() - (v.age_hours * INTERVAL '1 hour'))
  FROM (VALUES
    -- Borderline sanctions chain — third-tier supplier match
    (27, 'high', 'Possible sanctions chain hit — 3rd-tier subcontractor',
     'OFAC SDN list update 2026-05-29 names "Energy Holdings LLC" — entity-resolution finds a 67% string-similarity match to "Energy Holdings (UAE) LLC", a 3rd-tier subcontractor under Mubadala Investment Company. No exact match in the corporate graph. Manual review recommended before paging Compliance.',
     'sanctions-chain-3rdtier-2026w22', 'tier2-sanctions-chain', 12,
     jsonb_build_object('autoCreated', TRUE, 'tier', 2,
                        'suppressedReason', 'low_confidence',
                        'confidence', 0.67,
                        'severity', 'high',
                        'materialityAed', 5500000,
                        'ruleId', 'rule.sanctions.chain_exposure')),
    -- Borderline commodity / FX deviation
    (52, 'high', 'USD/AED peg deviation 0.38% — short-window',
     'CBUAE peg deviation crossed 0.25% but stayed below the 0.5% high threshold for a 6-hour window. Historical pattern suggests a transitory dip, not a peg-break event. Confidence below the Finance & Treasury auto-route floor.',
     'fx-peg-deviation-2026w22', 'tier2-fx-peg-deviation', 18,
     jsonb_build_object('autoCreated', TRUE, 'tier', 2,
                        'suppressedReason', 'low_confidence',
                        'confidence', 0.72,
                        'severity', 'high',
                        'materialityAed', 4220000000,
                        'ruleId', 'rule.fx.peg_deviation')),
    -- Borderline weather event — sustained-window not yet confirmed
    (243, 'high', 'NCM cyclone watch — sustained-window not yet confirmed',
     'NCM issued a Category-2 cyclone watch for the Persian Gulf 36h forecast. Force majeure eligibility depends on a 72h sustained-window which has not yet been confirmed. Operations triage premature; flagging here so executive can choose to pre-position.',
     'cyclone-watch-2026w22', 'tier2-weather-cyclone-watch', 24,
     jsonb_build_object('autoCreated', TRUE, 'tier', 2,
                        'suppressedReason', 'low_confidence',
                        'confidence', 0.78,
                        'severity', 'high',
                        'materialityAed', 14000000000,
                        'ruleId', 'rule.hormuz.supply_disruption'))
  ) AS v(contract_id, priority, title, body, dedupe_suffix, slug, age_hours, metadata)
WHERE NOT EXISTS (
  SELECT 1 FROM risk_case WHERE dedupe_key = 'review:seed:' || v.slug
);

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (550, 'routing_admin_and_tier_gates', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
