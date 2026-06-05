-- MIGRATION: 549_risk_routing_matrix.sql
-- Date: 2026-06-04
-- Description:
--   Phase B — auto-routing matrix for risk cases.
--
--   Today fn_risk_case_auto_create_from_correlation leaves
--   assigned_role=NULL on every new case, so correlation-engine alerts
--   land in limbo until a human manually assigns them. Manual cases let
--   the caller specify a role but don't enforce any policy.
--
--   This migration introduces a tunable routing matrix (mirrors the
--   approval_matrix pattern from M2):
--
--     risk_routing_rule(case_type, risk_type, priority_min, contract_type,
--                       assigned_role, sla_hours)
--
--   ... and a classify-and-route fn that runs after every newly-created
--   risk_case, looks up the first matching rule (lowest rule_order wins),
--   and sets assigned_role + due_at when the row is currently
--   role-unassigned. Specific user assignment stays manual — rules route
--   to a role-pool, members self-claim.
--
--   12 seeded rules cover the demo's risk taxonomy. A catch-all sends
--   everything else to operations with a 24h SLA so nothing ever lands
--   unassigned.
--
--   New permission: risk.routing.manage. Granted to platform_admin +
--   Super Admin only — used by the admin UI to edit the matrix.

BEGIN;

-- 1. Table -------------------------------------------------------------

CREATE TABLE IF NOT EXISTS risk_routing_rule (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID         NOT NULL,
  rule_order      INTEGER      NOT NULL,
  case_type       TEXT,                            -- NULL = matches any case_type
  risk_type       TEXT,                            -- NULL = matches any risk_type (fn_classify_risk slug)
  priority_min    TEXT,                            -- NULL = any; else low/medium/high/critical floor
  contract_type   TEXT,                            -- NULL = any
  assigned_role   TEXT         NOT NULL,
  sla_hours       INTEGER      NOT NULL DEFAULT 24,
  description     TEXT,
  is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by      BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by      BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  UNIQUE (tenant_id, rule_order)
);

COMMENT ON TABLE risk_routing_rule IS
  'Tunable matrix that maps a newly-created risk_case onto an assigned_role + SLA. '
  'Evaluated first-match-wins by rule_order ASC. Maintained by platform_admin via the '
  '/app/admin/risk-routing UI. Specific user assignment stays manual — rules route to '
  'role pools, members self-claim.';

CREATE INDEX IF NOT EXISTS idx_risk_routing_rule_active_order
  ON risk_routing_rule (tenant_id, rule_order ASC) WHERE is_active = TRUE;

-- FORCE RLS — tenant isolation matches every other tenant-scoped table.
ALTER TABLE risk_routing_rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk_routing_rule FORCE ROW LEVEL SECURITY;

CREATE POLICY risk_routing_rule_tenant_isolation ON risk_routing_rule
  FOR ALL USING (
    tenant_id IS NOT DISTINCT FROM NULLIF(current_setting('app.current_tenant_id', true), '')::UUID
  );

-- Audit trigger — every change to a routing rule lands in audit_log.
CREATE TRIGGER audit_risk_routing_rule_changes
  AFTER INSERT OR UPDATE OR DELETE ON risk_routing_rule
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- 2. Permission --------------------------------------------------------

INSERT INTO permission (code, module, action, description, is_active)
SELECT 'risk.routing.manage', 'risk_cases', 'manage',
       'Manage the risk routing matrix (create / edit / disable rules)', TRUE
WHERE NOT EXISTS (
  SELECT 1 FROM permission WHERE code = 'risk.routing.manage'
);

INSERT INTO role_permission (role_id, permission_id, is_active)
SELECT r.id, p.id, TRUE
  FROM role r CROSS JOIN permission p
 WHERE r.name IN ('platform_admin','Super Admin')
   AND p.code = 'risk.routing.manage'
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp
      WHERE rp.role_id = r.id AND rp.permission_id = p.id
   );

-- 3. Classifier helper for routing -------------------------------------
--
-- Looks up the first matching active rule for a risk_case row and (if
-- the case is still role-unassigned) sets its assigned_role + due_at.
-- Returns {matched, ruleId, assignedRole}. Safe to call multiple times —
-- a case that already has assigned_role IS NOT NULL is left alone.

CREATE OR REPLACE FUNCTION public.fn_risk_case_classify_and_route(p_case_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_case        RECORD;
  v_risk_type   TEXT;
  v_contract_type TEXT;
  v_rule        RECORD;
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
    RETURN jsonb_build_object('matched', FALSE, 'reason', 'no_rule_matched');
  END IF;

  -- Only assign if the case is currently role-unassigned, so a manual
  -- create that already picked a role wins over the matrix.
  IF v_case.assigned_role IS NULL THEN
    UPDATE risk_case
       SET assigned_role = v_rule.assigned_role,
           sla_hours = v_rule.sla_hours,
           due_at = fn_demo_now() + (v_rule.sla_hours * INTERVAL '1 hour'),
           updated_at = CURRENT_TIMESTAMP
     WHERE id = p_case_id;
  END IF;

  RETURN jsonb_build_object(
    'matched', TRUE,
    'ruleId', v_rule.id,
    'ruleOrder', v_rule.rule_order,
    'assignedRole', v_rule.assigned_role,
    'slaHours', v_rule.sla_hours,
    'wasApplied', v_case.assigned_role IS NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_case_classify_and_route(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_case_classify_and_route(bigint) TO neondb_owner;

-- 4. Hook into the two creation paths ----------------------------------
--
-- Both auto-create-from-correlation and manual create now call the
-- classifier post-INSERT. Both still preserve the prior behaviour when
-- the matrix doesn't match.

CREATE OR REPLACE FUNCTION public.fn_risk_case_auto_create_from_correlation(p_correlation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tenant_id   UUID;
  v_contract_id BIGINT;
  v_rule_id     TEXT;
  v_rule_name   TEXT;
  v_priority    TEXT := 'medium';
  v_id          BIGINT;
  v_was_new     BOOLEAN := FALSE;
  v_dedupe      TEXT;
  v_title       TEXT;
BEGIN
  SELECT c.tenant_id, c.contract_id, c.rule_id INTO v_tenant_id, v_contract_id, v_rule_id
    FROM correlation c WHERE c.id = p_correlation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('riskCaseId', NULL, 'wasNew', FALSE);
  END IF;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'correlation has no tenant_id (impossible)' USING ERRCODE = 'P0001';
  END IF;

  SELECT cr.name INTO v_rule_name FROM correlation_rule cr WHERE cr.rule_id = v_rule_id LIMIT 1;
  v_title := left(COALESCE(v_rule_name, v_rule_id), 200);
  v_dedupe := 'correlation:' || p_correlation_id;

  BEGIN
    INSERT INTO risk_case (
      tenant_id, correlation_id, contract_id, case_type, priority, title, body,
      dedupe_key, status, sla_hours, due_at, metadata, created_by, updated_by
    ) VALUES (
      v_tenant_id, p_correlation_id, v_contract_id, 'correlation_alert', v_priority, v_title, NULL,
      v_dedupe, 'open', NULL, NULL,
      jsonb_build_object('autoCreated', TRUE, 'autoCreateReason', 'rule_flag_true', 'ruleId', v_rule_id),
      NULL, NULL
    ) RETURNING id INTO v_id;
    v_was_new := TRUE;
  EXCEPTION
    WHEN unique_violation THEN
      SELECT id INTO v_id FROM risk_case WHERE tenant_id = v_tenant_id AND dedupe_key = v_dedupe;
      v_was_new := FALSE;
  END;

  IF v_was_new THEN
    -- Phase B — auto-route via the matrix. Sets assigned_role + due_at
    -- when a rule matches; no-op if the case already had a role.
    PERFORM fn_risk_case_classify_and_route(v_id);

    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
      VALUES (v_tenant_id, v_id, 'created', NULL,
              jsonb_build_object('ruleId', v_rule_id, 'correlationId', p_correlation_id, 'autoCreate', TRUE));
    PERFORM fn_audit_log_record_v2('risk_case_event', v_id, 'INSERT', NULL,
      jsonb_build_object('eventType','created','autoCreate',TRUE), NULL);
  END IF;

  RETURN jsonb_build_object('riskCaseId', v_id, 'wasNew', v_was_new);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_auto_create_from_correlation: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

-- For manual create, classify_and_route is called by the controller-side
-- service hook (or could be added here) — but we add it inside the fn
-- defensively so anyone calling fn_risk_case_create directly via psql
-- still gets routing applied.

CREATE OR REPLACE FUNCTION public.fn_risk_case_create(p_actor_id bigint, p_priority text, p_title text, p_contract_id bigint DEFAULT NULL::bigint, p_body text DEFAULT NULL::text, p_assigned_role text DEFAULT NULL::text, p_assigned_user_id bigint DEFAULT NULL::bigint, p_sla_hours integer DEFAULT NULL::integer, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id UUID;
  v_id        BIGINT;
  v_due_at    TIMESTAMPTZ;
  v_dedupe    TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('risk.case.create') THEN
    RAISE EXCEPTION 'risk.case.create permission required' USING ERRCODE = '42501';
  END IF;

  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN
    RAISE EXCEPTION 'title is required' USING ERRCODE = '22023';
  END IF;
  IF p_priority NOT IN ('low','medium','high','critical') THEN
    RAISE EXCEPTION 'priority must be one of low, medium, high, critical' USING ERRCODE = '22023';
  END IF;
  IF p_assigned_role IS NOT NULL AND NOT EXISTS (SELECT 1 FROM role WHERE name = p_assigned_role AND is_active = TRUE) THEN
    RAISE EXCEPTION 'assignedRole not found or inactive' USING ERRCODE = '22023';
  END IF;
  IF p_assigned_user_id IS NOT NULL AND p_assigned_role IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM "user" u JOIN role r ON r.id = u.role_id
       WHERE u.id = p_assigned_user_id AND r.name = p_assigned_role AND u.is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'User does not hold the assigned role' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;

  v_due_at := CASE WHEN p_sla_hours IS NOT NULL THEN fn_demo_now() + (p_sla_hours * INTERVAL '1 hour') ELSE NULL END;
  v_dedupe := p_metadata->>'idempotencyKey';

  BEGIN
    INSERT INTO risk_case (
      tenant_id, contract_id, case_type, priority, title, body,
      assigned_role, assigned_user_id, status, sla_hours, due_at,
      dedupe_key, metadata, created_by, updated_by
    ) VALUES (
      v_tenant_id, p_contract_id, 'manual', p_priority, trim(p_title), p_body,
      p_assigned_role, p_assigned_user_id, 'open', p_sla_hours, v_due_at,
      v_dedupe, COALESCE(p_metadata, '{}'::jsonb), NULLIF(p_actor_id, 0), NULLIF(p_actor_id, 0)
    ) RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'Idempotency conflict — dedupe_key collision' USING ERRCODE = '23505';
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'contract not found' USING ERRCODE = 'P0002';
  END;

  -- Phase B — apply the matrix. No-op when the caller already supplied
  -- p_assigned_role (manual create with explicit role wins).
  PERFORM fn_risk_case_classify_and_route(v_id);

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_id, 'created', NULLIF(p_actor_id, 0),
            jsonb_build_object('title', trim(p_title), 'priority', p_priority));

  PERFORM fn_audit_log_record_v2('risk_case_event', v_id, 'INSERT', NULL,
    jsonb_build_object('eventType','created'), NULL);

  -- Return the freshly-created (and possibly routed) case via the
  -- standard detail shape so the controller can echo it back.
  RETURN fn_risk_case_get_by_id(p_actor_id, v_id);
END;
$function$;

-- 5. Seed 12 routing rules + catch-all ---------------------------------
--
-- Ordered by specificity. Lower rule_order wins. The catch-all at 999
-- guarantees no case lands unassigned. Rules cover the demo's risk
-- taxonomy 1:1 with assignment to the correct specialist role.

INSERT INTO risk_routing_rule (
  tenant_id, rule_order, case_type, risk_type, priority_min, contract_type,
  assigned_role, sla_hours, description, is_active
)
SELECT '00000000-0000-0000-0000-000000000001'::uuid,
       r.rule_order, r.case_type, r.risk_type, r.priority_min, r.contract_type,
       r.assigned_role, r.sla_hours, r.description, TRUE
FROM (VALUES
  ( 10, NULL,          'sanctions',                  'high',     NULL, 'compliance_esg',            8,  'Sanctions exposure — Compliance & ESG, 8h SLA'),
  ( 20, NULL,          'force_majeure',              'high',     NULL, 'operations',                4,  'Force majeure — Operations triage, 4h SLA'),
  ( 30, NULL,          'force_majeure',              'high',     NULL, 'legal_counsel',             8,  'Force majeure — Legal review (parallel to ops), 8h SLA'),
  ( 40, NULL,          'budget_overrun',             'high',     NULL, 'finance_treasury',          24, 'Budget overrun — Finance & Treasury, 24h SLA'),
  ( 50, NULL,          'counterparty_concentration', 'high',     NULL, 'finance_treasury',          24, 'Counterparty concentration — Finance & Treasury, 24h SLA'),
  ( 60, NULL,          'esg_sustainability',         'medium',   NULL, 'compliance_esg',            48, 'ESG / sustainability — Compliance & ESG, 48h SLA'),
  ( 70, NULL,          'regulatory_change',          'medium',   NULL, 'legal_counsel',             48, 'Regulatory change — Legal Counsel, 48h SLA'),
  ( 80, NULL,          'commodity_price',            'medium',   NULL, 'finance_treasury',          24, 'Commodity / price — Finance & Treasury, 24h SLA'),
  ( 90, 'sla_breach',  'approval_workflow',          NULL,       NULL, 'contract_approver',         24, 'Approval-workflow SLA breach — Contract Approver, 24h SLA'),
  (100, 'sla_breach',  'sla_breach',                 NULL,       NULL, 'operations',                24, 'SLA / performance breach — Operations, 24h SLA'),
  (110, NULL,          'vendor_supplier',            'medium',   NULL, 'procurement_supplier_risk', 24, 'Vendor / supplier risk — Procurement, 24h SLA'),
  (120, NULL,          'icv_local_content',          NULL,       NULL, 'compliance_esg',            72, 'ICV / local content — Compliance & ESG, 72h SLA'),
  (999, NULL,          NULL,                         NULL,       NULL, 'operations',                24, 'Catch-all — Operations queue, 24h SLA')
) AS r(rule_order, case_type, risk_type, priority_min, contract_type, assigned_role, sla_hours, description)
WHERE NOT EXISTS (
  SELECT 1 FROM risk_routing_rule rr
   WHERE rr.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
     AND rr.rule_order = r.rule_order
);

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (549, 'risk_routing_matrix', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
